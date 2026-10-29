defmodule AiurPushRelay.MixProject do
  use Mix.Project

  def project do
    [app: :aiur_push_relay, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {AiurPushRelay.Application, []}]
  end

  defp deps do
    [{:bandit, "~> 1.14"}, {:plug, "~> 1.18"}, {:jason, "~> 1.4"}, {:exqlite, "~> 0.27"}]
  end
end
