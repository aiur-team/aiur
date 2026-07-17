defmodule Aiur.Claude.MeterTestSupport do
  @moduledoc false

  alias Aiur.Claude.AccountGeneration
  alias Aiur.ProviderAccountGeneration
  alias Aiur.ProviderMeters.Store

  def fixture(name),
    do: name |> fixture_path() |> File.read!() |> Jason.decode!()

  def fixture_path(name),
    do: Path.expand("../fixtures/claude/#{name}", __DIR__)

  def ensure_pubsub do
    unless Process.whereis(Aiur.PubSub) do
      ExUnit.Callbacks.start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  def sequence_mint do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      "claude-generation-#{:counters.get(counter, 1)}"
    end
  end

  def generation_session(server) do
    account_generation = AccountGeneration.new_binding(server)

    %{
      account_generation_binding: account_generation.binding,
      account_generation_authority: account_generation.authority,
      account_generation_context: account_generation.context,
      account_generation_topic: account_generation.topic,
      account_generation_server: server
    }
  end

  def account_meter_context(now) do
    ensure_pubsub()
    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil, mint: sequence_mint())
    {:ok, store} = Store.start_link(name: nil, account_generation_owner: owner, clock: fn -> now end)

    session =
      owner
      |> generation_session()
      |> Map.merge(%{
        provider_meter_ingester: &Store.ingest(store, &1),
        provider_meter_failure_recorder: &Store.record_failure(store, &1)
      })

    %{
      owner: owner,
      store: store,
      session: session,
      binding: session.account_generation_binding
    }
  end
end
