defmodule AgentConversation.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_conversation,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Function components only; the package never mounts a live view of its own.
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.4"},
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.38", only: :test}
    ]
  end
end
