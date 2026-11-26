defmodule VoiceTranscribe.MixProject do
  use Mix.Project

  def project do
    [
      app: :voice_transcribe,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:mint, "~> 1.7"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
