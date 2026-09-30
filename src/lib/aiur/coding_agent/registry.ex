defmodule Aiur.CodingAgent.Registry do
  @moduledoc "Provider-owned backend definitions behind the stable CodingAgent registry API."

  alias Aiur.CodingAgent.Providers.{Claude, Codex, Gemini, Muse}

  @spec entries() :: %{String.t() => Aiur.CodingAgent.Backend.capabilities()}
  def entries do
    %{
      "codex" => Codex.entry(),
      "claude" => Claude.headless(),
      "claude-repl" => Claude.repl(),
      "muse" => Muse.entry(),
      "gemini" => Gemini.entry()
    }
    |> Map.merge(Aiur.OpenAICompat.Registry.entries())
    |> maybe_add_test_backend()
  end

  # This fixture uses the same registry path as production backends so consumers
  # cannot special-case it in their dispatch, presentation, or usage paths.
  if Mix.env() == :test do
    alias Aiur.CodingAgent.Providers.Fake

    @spec maybe_add_test_backend(map()) :: map()
    defp maybe_add_test_backend(backends),
      do: Map.put(backends, "fake", Fake.entry())
  else
    @spec maybe_add_test_backend(map()) :: map()
    defp maybe_add_test_backend(backends), do: backends
  end
end
