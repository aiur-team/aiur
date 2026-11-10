defmodule Aiur.Capacity.ViewTest do
  @moduledoc "The `aiur.capacity` v1 view (#7893) is built by the functions dispatch calls and matches its schema."

  use Aiur.TestSupport

  alias Aiur.Accounts.UsageReadings
  alias Aiur.Capacity.View

  @now ~U[2026-10-10 06:00:00Z]
  @backends ["codex", "claude", "openrouter"]
  @policy %{
    sources: %{
      "claude" => %{billing: "subscription", reserve: %{percent: 30, accounts: ["default"]}},
      "codex" => %{billing: "subscription"},
      "openrouter" => %{billing: "prepaid", last_resort: true, limits: %{daily_usd: 5}}
    }
  }

  setup do
    UsageReadings.reset()
    on_exit(&UsageReadings.reset/0)
    :ok
  end

  defp claude_meter(used) do
    fn
      "claude", names ->
        for "default" = name <- names, into: %{} do
          {name, %{reading: %{windows: [%{window: "seven_day", used_percent: used}]}, observed_at: DateTime.add(@now, -40), freshness: :fresh}}
        end

      _harness, _names ->
        %{}
    end
  end

  defp opts(overrides) do
    ledger_path = Path.join(Aiur.TestSupport.tmp_root!("capacity-view-ledger"), "model-usage.json")
    File.mkdir_p!(Path.dirname(ledger_path))
    File.write!(ledger_path, Jason.encode!(%{"backends" => %{}}))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(ledger_path)) end)

    Keyword.merge(
      [
        routes: @backends,
        account_selection: "headroom",
        routing_candidates: %{},
        priority_backends: @backends,
        backends: @backends,
        configured_backends: @backends,
        accounts: %{"claude" => ["default"]},
        account_list_fun: fn
          "claude" -> [%{name: "default"}]
          _harness -> []
        end,
        account_capability_fun: fn
          "claude" -> {:ok, %{supported: true, multi: :available}}
          _harness -> {:error, :unsupported_account_backend}
        end,
        api_key_fetcher: fn _env -> "test-key" end,
        provider_view_fun: fn _provider -> nil end,
        usage_floor_percent_fun: fn _backend -> 5 end,
        usage_snapshot: claude_meter(10),
        state: %{"backends" => %{}},
        path: ledger_path,
        probe_fun: fn _backend, _options -> :ok end,
        avoid_peak_pricing: false,
        capacity_policy: @policy,
        capacity_holds: [],
        now: @now
      ],
      overrides
    )
  end

  defp valid!(view) do
    schema =
      Path.expand("../../../../packages/aiur-contracts/schemas/capacity.v1.schema.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.delete("$schema")
      |> ExJsonSchema.Schema.resolve()

    assert ExJsonSchema.Validator.validate(schema, view |> Jason.encode!() |> Jason.decode!()) == :ok
    view
  end

  defp source(view, backend), do: Enum.find(view.sources, &(&1.backend == backend))

  test "claude's headroom above its reserve is the energy level; holds lower the projection" do
    view = opts(capacity_holds: [%{route: "claude", account: "default", estimate_percent: 20}]) |> View.build() |> valid!()

    assert %{state: "available", level: 0.4, binding_source: "claude", freshness: "fresh", age_ms: 40_000} = view.energy
    assert %{state: "available", accounts: [account]} = source(view, "claude")
    assert %{reserved: true, remaining_percent: 90.0, projected_percent: 70.0, reserve_percent: 30, open_holds: 1} = account
    # Dispatch passes no spend, so a set limit holds the source on unknown spend, here as there.
    assert %{state: "held", reason: "spend_unknown", limits: [%{period: "daily", spent_usd: nil, freshness: "unknown"}]} = source(view, "openrouter")
    assert %{state: "last_resort", reason: "last_resort"} = opts(capacity_policy: put_in(@policy.sources["openrouter"][:limits], nil)) |> View.build() |> valid!() |> source("openrouter")
  end

  test "claude below its reserve shows reserved, as dispatch holds it" do
    view = opts(usage_snapshot: claude_meter(75)) |> View.build() |> valid!()
    assert %{state: "reserved", reason: "reserve"} = source(view, "claude")
    # codex is allowed but has no reading, so energy is unknown, not exhausted at 0.
    assert %{state: "unknown", level: nil} = view.energy
  end

  test "the text view shows each known figure's age" do
    text = opts([]) |> View.build() |> View.render()
    assert text =~ "Energy: available 60% via claude (fresh, 40s ago)"
    assert text =~ ~r/default .*holds, fresh, 40s ago/
  end

  test "with no known figure the level is null, not empty or full" do
    view = opts(usage_snapshot: fn _harness, _names -> %{} end) |> View.build() |> valid!()

    assert %{state: "unknown", level: nil, binding_source: nil, freshness: "unknown", observed_at: nil} = view.energy
    assert Enum.sort(view.energy.unknown_sources) == Enum.sort(@backends)
    assert View.render(view) =~ "Energy: unknown (unknown)"
  end
end
