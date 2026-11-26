defmodule LocalHost.MixProject do
  use Mix.Project

  def project do
    [app: :local_host, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :crypto], mod: {LocalHost.Application, []}]

  defp deps do
    [{:voice_converse, path: "../.."}, {:bandit, "~> 1.12"}, {:websock_adapter, "~> 0.6"}]
  end
end
