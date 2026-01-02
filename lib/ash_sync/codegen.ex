defmodule AshSync.Codegen do
  def codegen(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [output: :string, name: :string],
        aliases: [o: :output]
      )

    output_dir =
      Keyword.get(opts, :output) ||
        Application.get_env(:ash_sync, :output_dir, "assets/js/client")

    resources =
      Mix.Project.config()[:app]
      |> Ash.Info.domains()
      |> Enum.flat_map(fn domain ->
        AshSync.Info.sync(domain)
      end)

    skip = Application.get_env(:ash_sync, :skip, [])
    api_base = Application.get_env(:ash_sync, :api_base)

    File.mkdir_p!(output_dir)

    opts = %{output_dir: output_dir, api_base: api_base}

    [
      {:query, &generate_query/2},
      {:collections, &generate_collections/2},
      {:schema, &generate_schema/2},
      {:ingest, &generate_ingest/2}
    ]
    |> Enum.reject(fn {name, _fun} -> name in skip end)
    |> Enum.each(fn {_name, fun} -> fun.(resources, opts) end)
  end

  defp url_helpers(api_base) do
    default_base =
      if api_base do
        ~s|const DEFAULT_API_BASE = "#{api_base}";|
      else
        "const DEFAULT_API_BASE: string | undefined = undefined;"
      end

    """
    #{default_base}

    const getApiBase = (): string => {
      if (DEFAULT_API_BASE) return DEFAULT_API_BASE;

      if (typeof window !== "undefined") {
        return window.location.origin;
      }

      throw new Error("No API base URL available: not in browser and no DEFAULT_API_BASE configured");
    };

    const getUrl = (path: string) => `${getApiBase()}${path}`;
    """
  end

  # The idea here is that we can accept arbitrary mutations.
  # Left out of the prototype for now.
  # defp generate_mutations(resources) do
  #   mutations =
  #     resources
  #     |> Enum.flat_map(fn resource ->
  #       Enum.map(resource.mutations, fn mutation ->
  #         {resource.resource, mutation}
  #       end)
  #     end)
  #     |> Enum.map_join("\n", fn {resource, mutation} ->
  #       mutation_name = "#{Macro.camelize(to_string(mutation.name))}"
  #       action = Ash.Resource.Info.action(resource, mutation.action)

  #       action_inputs =
  #         resource
  #         |> Ash.Resource.Info.action_inputs(action.name)
  #         |> Enum.filter(&is_atom/1)
  #         |> Enum.map(fn name ->
  #           Enum.find(action.arguments, &(&1.name == name)) ||
  #             Ash.Resource.Info.attribute(resource, name)
  #         end)

  #       params_name = "#{mutation_name}Params"

  #       has_inputs? = not Enum.empty?(action_inputs)

  #       params =
  #         if has_inputs? do
  #           "{input: input}"
  #         else
  #           "{}"
  #         end

  #       type_definition =
  #         if has_inputs? do
  #           """
  #           type #{params_name} = {
  #             input: {
  #           #{Enum.map_join(action_inputs, ";\n", &"    #{&1.name}: #{to_input_type(&1)}")}
  #             }
  #           };
  #           """
  #         else
  #           """
  #           type #{params_name} = {};
  #           """
  #         end

  #       """
  #       #{type_definition}export function #{mutation_name}(#{params}: #{params_name}) {
  #         fetch(relativeUrl('/mutate/'), {
  #           method: "POST",
  #           body: JSON.stringify(input)
  #         })
  #       }
  #       """
  #     end)

  #   contents = """
  #   const relativeUrl = (path) => (
  #     `${window.location.origin}${path}`
  #   )

  #   #{mutations}
  #   """

  #   File.write!("assets/js/client/mutations.ts", contents)
  # end

  defp generate_ingest(resources, %{output_dir: output_dir, api_base: api_base}) do
    resources =
      Enum.reject(resources, fn resource ->
        Enum.all?(resource.queries, fn query ->
          !query.on_update && !query.on_insert && !query.on_delete
        end)
      end)

    if !Enum.empty?(resources) do
      types_to_import =
        resources
        |> Enum.map(fn %{resource: resource} ->
          resource_type_name(resource)
        end)
        |> case do
          [] ->
            ""

          resources ->
            "\nimport type { #{Enum.join(resources, ", ")} } from './schema';"
        end

      types_union =
        resources
        |> Enum.map(fn %{resource: resource} ->
          resource_type_name(resource)
        end)
        |> case do
          [] ->
            ""

          resources ->
            Enum.join(resources, " | ")
        end

      contents =
        """
        import type {
          Collection,
          MutationFn,
          PendingMutation
        } from '@tanstack/react-db';#{types_to_import}

        import { ElectricCollection } from "@tanstack/db-collections";

        #{url_helpers(api_base)}
        export const ingestMutations: MutationFn = async ({ transaction }) => {
          const payload = transaction.mutations.map(
            (mutation: PendingMutation<#{types_union}>) => {
              const { collection: _, ...rest } = mutation

              return { ...rest, query: mutation.collection.config.id };
            }
          )

          const response = await fetch(getUrl('/ingest/mutations'), {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
          })

          if (!response.ok) {
            throw new Error(`HTTP Error: ${response.status}`)
          }

          const result = await response.json()

          const collection = transaction.mutations[0]!.collection as ElectricCollection;
          await collection.awaitTxId(result.txid);
        }
        """

      File.write!(Path.join(output_dir, "ingest.ts"), contents)
    end
  end

  defp generate_schema(resources, %{output_dir: output_dir}) do
    main_resources =
      resources
      |> Enum.map(& &1.resource)
      |> Enum.uniq()

    embedded_resources = collect_embedded_resources(main_resources)

    embedded_type_defs =
      embedded_resources
      |> Enum.map_join("\n", fn embedded ->
        generate_schema_for_resource(embedded, &embedded_type_name/1)
      end)

    resource_type_defs =
      main_resources
      |> Enum.map_join("\n", fn resource ->
        generate_schema_for_resource(resource, &resource_type_name/1)
      end)

    schema_contents =
      """
      import { z } from 'zod';

      #{embedded_type_defs}
      #{resource_type_defs}
      """

    File.write!(Path.join(output_dir, "schema.ts"), schema_contents)
  end

  defp generate_schema_for_resource(resource, name_fn) do
    attributes = Ash.Resource.Info.attributes(resource)
    type_name = name_fn.(resource)
    schema_name = "#{lowercase_first(type_name)}Schema"

    attr_defs =
      Enum.map_join(attributes, ",\n", fn attr ->
        base_type = to_read_type(attr)
        is_nullable = Map.get(attr, :allow_nil?, true)
        is_primary_key = attr.primary_key?

        zod_type =
          if is_nullable && !is_primary_key do
            "#{base_type}.nullable()"
          else
            base_type
          end

        "  #{attr.name}: #{zod_type}"
      end)

    """
    export const #{schema_name} = z.object({
    #{attr_defs}
    });
    export type #{type_name} = z.infer<typeof #{schema_name}>;
    """
  end

  defp collect_embedded_resources(resources) do
    resources
    |> Enum.flat_map(fn resource ->
      Ash.Resource.Info.attributes(resource)
      |> Enum.flat_map(fn attr ->
        find_embedded_types(attr.type)
      end)
    end)
    |> Enum.uniq()
  end

  defp find_embedded_types({:array, inner_type}), do: find_embedded_types(inner_type)

  defp find_embedded_types(type) when is_atom(type) do
    if is_embedded_resource?(type), do: [type], else: []
  end

  defp find_embedded_types(_), do: []

  defp generate_query(resources, %{output_dir: output_dir, api_base: api_base}) do
    types_to_import =
      resources
      |> Enum.reject(&Enum.empty?(&1.queries))
      |> Enum.map(fn %{resource: resource} ->
        resource_type_name(resource)
      end)
      |> case do
        [] ->
          ""

        resources ->
          "\nimport type { #{Enum.join(resources, ", ")} } from './schema';"
      end

    query_defs =
      Enum.map_join(resources, "\n", fn %{resource: resource, queries: queries} ->
        Enum.map_join(queries, "\n", fn %{name: name, action: action} ->
          action = Ash.Resource.Info.action(resource, action)

          action_inputs =
            resource
            |> Ash.Resource.Info.action_inputs(action.name)
            |> Enum.filter(&is_atom/1)
            |> Enum.map(fn name ->
              Enum.find(action.arguments, &(&1.name == name)) ||
                Ash.Resource.Info.attribute(resource, name)
            end)

          query_name = "#{Macro.camelize(to_string(name))}"

          params_name = "#{query_name}Params"
          resource_type_name = resource_type_name(resource)

          has_inputs? = not Enum.empty?(action_inputs)

          ignored_opts = Enum.map_join(["url", "params", "parser"], " | ", &"'#{&1}'")

          type_definition =
            if has_inputs? do
              """
              type #{params_name} = {
                input: {
              #{Enum.map_join(action_inputs, ";\n", &"    #{&1.name}: #{to_input_type(&1)}")}
                },
                options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
              };
              """
            else
              """
              type #{params_name} = {
                options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
              };
              """
            end

          input_destructure =
            if has_inputs? do
              "inputs, "
            end

          input_params_option =
            if has_inputs? do
              "{query: '#{name}', input: inputs}"
            else
              "{query: '#{name}'}"
            end

          """
          #{type_definition}
          export function #{lowercase_first(query_name)}({ #{input_destructure}options }: #{params_name} = {}): Shape<#{resource_type_name}> {
            const stream = new ShapeStream<#{resource_type_name}>({
              ...options,
              params: #{input_params_option},
              url: getUrl('/api/sync/'),
            });

            return new Shape(stream);
          }
          """
        end)
      end)

    queries_content =
      """
      import { Shape, ShapeStream, ShapeStreamOptions } from "@electric-sql/client";#{types_to_import}

      #{url_helpers(api_base)}
      #{query_defs}
      """

    File.write!(Path.join(output_dir, "queries.ts"), queries_content)
  end

  defp generate_collections(resources, %{output_dir: output_dir, api_base: api_base}) do
    types_to_import =
      resources
      |> Enum.reject(&Enum.empty?(&1.queries))
      |> Enum.map(fn %{resource: resource} ->
        resource_type_name(resource)
      end)
      |> case do
        [] ->
          ""

        resources ->
          "\nimport type { #{Enum.join(resources, ", ")} } from './schema';"
      end

    collection_defs =
      Enum.map_join(resources, "\n", fn %{resource: resource, queries: queries} ->
        Enum.map_join(queries, "\n", fn %{name: name, action: action} ->
          action = Ash.Resource.Info.action(resource, action)

          action_inputs =
            resource
            |> Ash.Resource.Info.action_inputs(action.name)
            |> Enum.filter(&is_atom/1)
            |> Enum.map(fn name ->
              Enum.find(action.arguments, &(&1.name == name)) ||
                Ash.Resource.Info.attribute(resource, name)
            end)

          query_name = "#{Macro.camelize(to_string(name))}"
          collection_name = "#{lowercase_first(query_name)}Collection"

          resource_type_name = resource_type_name(resource)

          has_inputs? = not Enum.empty?(action_inputs)

          input_params_option =
            if has_inputs? do
              "{query: '#{name}', input: inputs}"
            else
              "{query: '#{name}'}"
            end

          """
          export const #{collection_name} = createCollection(
            electricCollectionOptions<#{resource_type_name}>({
              id: '#{name}',
              getKey: (item) => item.id,
              shapeOptions: {
                url: getUrl('/api/sync/'),
                params: #{input_params_option},
              },
            }),
          );
          """
        end)
      end)

    collections_content =
      """
      import { createCollection } from "@tanstack/db";
      import { electricCollectionOptions } from "@tanstack/electric-db-collection";#{types_to_import}

      #{url_helpers(api_base)}
      #{collection_defs}
      """

    File.write!(Path.join(output_dir, "collections.ts"), collections_content)
  end

  defp lowercase_first(string) do
    {first, rest} = String.split_at(string, 1)
    String.downcase(first) <> rest
  end

  # TODO make configurable
  defp resource_type_name(resource) do
    resource
    |> Module.split()
    |> Enum.reverse()
    |> Enum.take(2)
    |> Enum.reverse()
    |> Enum.join("")
  end

  # TODO: handle defaults, emit (probably statefully with an agent or somethign)
  # additional things that must be imported into the types file for this to work
  # for instance, uuids will need to import a function to create uuids
  defp to_read_type(%{type: Ash.Type.String}), do: "z.string()"
  defp to_read_type(%{type: Ash.Type.UUID}), do: "z.string().uuid()"
  defp to_read_type(%{type: Ash.Type.Float}), do: "z.number()"
  defp to_read_type(%{type: Ash.Type.Integer}), do: "z.number().int()"
  defp to_read_type(%{type: Ash.Type.Boolean}), do: "z.boolean()"
  defp to_read_type(%{type: Ash.Type.Map}), do: "z.record(z.string(), z.unknown())"
  defp to_read_type(%{type: Ash.Type.UtcDatetime}), do: "z.string().datetime()"

  defp to_read_type(%{type: Ash.Type.Atom, constraints: constraints}) do
    case Keyword.get(constraints, :one_of) do
      nil -> "z.string()"
      values -> "z.enum([#{Enum.map_join(values, ", ", &"\"#{&1}\"")}])"
    end
  end

  defp to_read_type(%{type: {:array, inner_type}, constraints: constraints}) do
    item_constraints = Keyword.get(constraints, :items, [])
    inner_zod = to_read_type(%{type: inner_type, constraints: item_constraints, allow_nil?: false})
    "z.array(#{inner_zod})"
  end

  defp to_read_type(%{type: Ash.Type.DateTime, constraints: [precision: :microsecond]}),
    do: "z.string().datetime({ precision: 3})"

  defp to_read_type(%{type: Ash.Type.DateTime}), do: "z.string().datetime()"

  defp to_read_type(%{type: type, constraints: constraints} = attr) do
    cond do
      Ash.Type.NewType.new_type?(type) ->
        sub_type_constraints = Ash.Type.NewType.constraints(type, constraints)
        subtype = Ash.Type.NewType.subtype_of(type)
        to_read_type(%{attr | type: subtype, constraints: sub_type_constraints})

      is_embedded_resource?(type) ->
        embedded_schema_name(type)

      true ->
        raise "unsupported type #{inspect(type)}"
    end
  end

  defp is_embedded_resource?(type) when is_atom(type) do
    Code.ensure_loaded?(type) &&
      function_exported?(type, :spark_is, 0) &&
      type.spark_is() == Ash.Resource &&
      Ash.Resource.Info.embedded?(type)
  rescue
    _ -> false
  end

  defp is_embedded_resource?(_), do: false

  defp embedded_schema_name(module) do
    module
    |> embedded_type_name()
    |> lowercase_first()
    |> Kernel.<>("Schema")
  end

  defp embedded_type_name(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp to_input_type(%{type: Ash.Type.String}), do: "z.string()"
  defp to_input_type(%{type: Ash.Type.UUID}), do: "z.string().uuid()"
  defp to_input_type(%{type: Ash.Type.Float}), do: "z.number()"
  defp to_input_type(%{type: Ash.Type.Integer}), do: "z.number().int()"
  defp to_input_type(%{type: Ash.Type.Boolean}), do: "z.boolean()"
  defp to_input_type(%{type: Ash.Type.Map}), do: "z.record(z.string(), z.unknown())"
  defp to_input_type(%{type: Ash.Type.UtcDatetime}), do: "z.string().datetime()"

  defp to_input_type(%{type: Ash.Type.Atom, constraints: constraints}) do
    case Keyword.get(constraints, :one_of) do
      nil -> "z.string()"
      values -> "z.enum([#{Enum.map_join(values, ", ", &"\"#{&1}\"")}])"
    end
  end

  defp to_input_type(%{type: {:array, inner_type}, constraints: constraints}) do
    item_constraints = Keyword.get(constraints, :items, [])
    inner_zod = to_input_type(%{type: inner_type, constraints: item_constraints, allow_nil?: false})
    "z.array(#{inner_zod})"
  end

  defp to_input_type(%{type: Ash.Type.DateTime, constraints: [precision: :microsecond]}),
    do: "z.string().datetime()"

  defp to_input_type(%{type: Ash.Type.DateTime}), do: "z.string().datetime()"

  defp to_input_type(%{type: type, constraints: constraints} = attr) do
    cond do
      Ash.Type.NewType.new_type?(type) ->
        sub_type_constraints = Ash.Type.NewType.constraints(type, constraints)
        subtype = Ash.Type.NewType.subtype_of(type)
        to_input_type(%{attr | type: subtype, constraints: sub_type_constraints})

      is_embedded_resource?(type) ->
        embedded_schema_name(type)

      true ->
        raise "unsupported type #{inspect(type)}"
    end
  end
end
