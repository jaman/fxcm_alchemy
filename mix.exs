defmodule FxcmAlchemy.MixProject do
  use Mix.Project

  def project do
    [
      app: :fxcm_alchemy,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:fix_alchemy, "~> 0.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:fxlite_alchemy, github: "jaman/fxlite_alchemy", optional: true},
      {:duckdbex, "~> 0.3", optional: true}
    ]
  end
end
