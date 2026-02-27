defmodule Resiliency.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/yoavgeva/resiliency"

  def project do
    [
      app: :resiliency,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      name: "Resiliency",
      description:
        "Resilience and concurrency toolkit for Elixir — retry, hedged requests, single-flight, task combinators, and weighted semaphore."
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extra_section: "GUIDES",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/choosing-a-pattern.md",
        "guides/combining-patterns.md",
        "guides/tuning-and-observability.md",
        "cheatsheets/resiliency.cheatmd",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/choosing-a-pattern.md",
          "guides/combining-patterns.md",
          "guides/tuning-and-observability.md"
        ],
        Cheatsheets: [
          "cheatsheets/resiliency.cheatmd"
        ]
      ],
      groups_for_modules: [
        Retry: [Resiliency.BackoffRetry, Resiliency.BackoffRetry.Backoff],
        "Hedged Requests": [
          Resiliency.Hedged,
          Resiliency.Hedged.Tracker,
          Resiliency.Hedged.Percentile
        ],
        "Single Flight": [Resiliency.SingleFlight],
        "Task Combinators": [Resiliency.TaskExtension],
        Semaphore: [Resiliency.WeightedSemaphore]
      ]
    ]
  end
end
