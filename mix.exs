defmodule Fleet.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: deps(),
      aliases: [setup: ["deps.get", "compile"], demo: ["run --no-halt"]]
    ]
  end

  def application do
    [mod: {Fleet.Application, []}, extra_applications: [:logger, :os_mon]]
  end

  defp deps do
    [
      {:durable_server, path: "vendor/durable_server", env: :prod},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.10"},
      {:jason, "~> 1.4"}
    ]
  end
end
