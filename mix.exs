defmodule TwoPhaseCommit.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :two_phase_commit,
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env),
      deps: deps(),
      dialyzer: [
        flags: [:unmatched_returns, :error_handling, :race_conditions, :no_opaque, :underspecs],
      ],

      description: "Two Phase Commit state machine model.",
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:propcheck, "~> 1.2", only: [:test, :dev]},
      {:dialyxir, "~> 1.0.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [maintainers: ["Michael Shapiro"],
     licenses: ["MIT"],
     links: %{"GitHub": "https://github.com/chassisframework/two_phase_commit"}]
  end

  defp docs do
    [extras: ["README.md"],
     source_url: "https://github.com/chassisframework/two_phase_commit",
     source_ref: @version,
     assets: "assets",
     main: "readme"]
  end
end
