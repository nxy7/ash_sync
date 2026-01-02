defmodule AshSync.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_sync,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:spark, "~> 2.3"},
      {:ash, "~> 3.11"},
      {:ash_postgres, "~> 2.6"},
      {:ash_phoenix, "~> 2.3"},
      {:electric_client, "~> 0.7.2"},
      {:igniter, "~> 0.7", optional: true},
      {:phoenix_sync, "~> 0.6"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
