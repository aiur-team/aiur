defmodule Aiur.ProviderMeterProjectionIntegrationTest do
  @moduledoc """
  Proves the end-to-end property the whole surface rests on: an observation
  ingested against a per-session binding becomes readable by a consumer that
  holds no binding at all. That gap is why the dashboard has always rendered
  the unknown-identity card.
  """

  use ExUnit.Case, async: false

  alias Aiur.{ProviderAccountGeneration, ProviderMeterProjection}
  alias Aiur.ProviderMeters.Store

  @now ~U[2026-07-27 12:00:00Z]

  setup do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil, mint: sequence_mint())
    {:ok, store} = Store.start_link(name: nil, account_generation_owner: owner, clock: fn -> @now end)

    projection_name = :"projection_int_#{System.unique_integer([:positive])}"

    {:ok, _projection} =
      ProviderMeterProjection.start_link(
        name: projection_name,
        clock: fn -> DateTime.add(@now, 90, :second) end
      )

    %{owner: owner, store: store, projection: projection_name}
  end

  test "a binding-scoped ingest becomes readable without a binding", ctx do
    binding = bound_binding(ctx.owner)

    assert {:ok, _snapshot} = Store.ingest(ctx.store, update(binding, windows: [window("session", used_percent: 63)]))

    view = await_observed(ctx.projection, :codex)

    assert view.state == :observed
    assert view.observed_at == @now
    assert view.age_seconds == 90
    assert view.windows["session"].used_percent == 63
  end

  test "the consumer view never carries the opaque account generation", ctx do
    binding = bound_binding(ctx.owner)
    assert {:ok, snapshot} = Store.ingest(ctx.store, update(binding, windows: [window("session")]))

    generation = snapshot.provider_account_generation
    assert is_binary(generation)

    view = await_observed(ctx.projection, :codex)

    refute view |> inspect(limit: :infinity) |> String.contains?(generation),
           "the account generation leaked into the consumer projection"
  end

  defp await_observed(projection, provider, attempts \\ 50) do
    view = ProviderMeterProjection.snapshot(projection, provider)

    cond do
      view.state == :observed -> view
      attempts == 0 -> flunk("projection never observed #{provider}")
      true -> Process.sleep(10) && await_observed(projection, provider, attempts - 1)
    end
  end

  defp bound_binding(owner) do
    assert {:ok, binding} = ProviderAccountGeneration.issue_binding(owner, :codex, :app_server)

    assert {:ok, %{generation: generation}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert is_binary(generation)
    binding
  end

  defp update(binding, overrides) do
    Map.merge(
      %{
        schema_version: 1,
        update_kind: :snapshot,
        provider: :codex,
        backend: :app_server,
        account_generation_binding: binding,
        auth_mode: :subscription,
        observed_at: @now,
        source: :synthetic,
        source_version: 1,
        windows: []
      },
      Map.new(overrides)
    )
  end

  defp window(limit_id, overrides \\ []) do
    Map.merge(
      %{
        limit_id: limit_id,
        kind: :rate_limit,
        name: :primary,
        used_percent: 25,
        duration_minutes: 300,
        source: :synthetic,
        observed_at: @now,
        coverage: :supported
      },
      Map.new(overrides)
    )
  end

  defp sequence_mint do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      "generation-#{:counters.get(counter, 1)}"
    end
  end
end
