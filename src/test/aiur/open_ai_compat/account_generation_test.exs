defmodule Aiur.OpenAICompat.AccountGenerationTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.AccountGeneration
  alias Aiur.ProviderAccountGeneration

  test "binds an API key to the registry-declared provider scope without retaining the key" do
    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil)
    session = AccountGeneration.new_binding("kimi", owner)

    assert :ok = AccountGeneration.bind(session)
    assert %{generation: generation, backend: :openai_compat, source: :kimi_api_key} = AccountGeneration.snapshot(session)
    assert is_binary(generation)
    refute inspect(session) =~ "MOONSHOT"

    assert :ok = AccountGeneration.process_stopped(session)

    assert %{generation: nil, reason: :continuity_lost} =
             ProviderAccountGeneration.lookup(owner, :kimi, :openai_compat, session.account_generation_binding)
  end
end
