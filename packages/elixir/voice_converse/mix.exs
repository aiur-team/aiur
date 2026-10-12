defmodule VoiceConverse.MixProject do
  use Mix.Project

  def project do
    [
      app: :voice_converse,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: ["lib"],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mint, "~> 1.7"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      # Optional local transport (MP-E6-C11-T02); compiled only when the host has them.
      {:websock_adapter, "~> 0.6", optional: true},
      {:bandit, "~> 1.12", optional: true}
    ]
  end
end
