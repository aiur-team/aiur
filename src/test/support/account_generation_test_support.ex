defmodule Aiur.Codex.AccountGenerationTestSupport do
  @moduledoc false

  alias Aiur.Codex.AccountGeneration
  alias Aiur.ProviderAccountGeneration

  def sequence_mint do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      value = :counters.get(counter, 1)
      "generation-#{value}"
    end
  end

  def start_owner(opts) do
    {:ok, owner} = ProviderAccountGeneration.start_link(Keyword.put(opts, :name, nil))
    owner
  end

  def session_for(server) do
    account_generation = AccountGeneration.new_binding(server)

    %{
      account_generation_binding: account_generation.binding,
      account_generation_authority: account_generation.authority,
      account_generation_context: account_generation.context,
      account_generation_topic: account_generation.topic,
      account_generation_server: server
    }
  end

  def default_context do
    owner = start_owner(mint: sequence_mint(), clock: fn -> ~U[2026-07-13 12:00:00Z] end)
    %{owner: owner, session: session_for(owner)}
  end
end
