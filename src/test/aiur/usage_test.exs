defmodule Aiur.UsageTest do
  use ExUnit.Case, async: true
  alias Aiur.Usage.Alerts
  alias Aiur.Usage.CLI
  alias Aiur.Usage.Provider.{Broker, Claude, Codex, GitHub, Ticket}

  test "registry includes supported providers and leaves netlify for its adapter" do
    assert Enum.sort(Aiur.Usage.providers()) == [:broker, :claude, :codex, :github, :ticket]
    assert {:error, :unknown_provider} = Aiur.Usage.provider("netlify", [])
  end

  test "every unavailable provider remains unknown instead of becoming zero" do
    cases = [
      {"claude", [meter_views: %{}]},
      {"codex", [meter_views: %{}]},
      {"github", [github_quota: %{state: :unknown, windows: %{}}]},
      {"broker", [broker_usage: %{}]},
      {"ticket", [ticket_usage: %{}]}
    ]

    for {provider, opts} <- cases do
      assert {:ok, record} = Aiur.Usage.provider(provider, opts)
      assert record["freshness"] == "unknown", provider
      assert record["observed_at"] == nil, provider
      assert record["age_ms"] == nil, provider
      refute Map.has_key?(record["fields"], "remaining_percent"), provider
    end
  end

  test "GitHub usage carries the newest observed window timestamp" do
    newer = DateTime.utc_now() |> DateTime.truncate(:second)
    older = DateTime.add(newer, -60, :second)

    assert {:ok, record} =
             Aiur.Usage.provider("github",
               github_quota: %{
                 state: :observed,
                 windows: %{
                   core: %{observed_at: older},
                   graphql: %{observed_at: newer}
                 }
               }
             )

    assert record["observed_at"] == DateTime.to_iso8601(newer)
    assert record["age_ms"] >= 0
    assert record["freshness"] == "fresh"
  end

  test "provider adapters preserve observed fixture fields" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    window = %{name: "Session", used_percent: 40, observed_at: now}
    meter_view = %{state: :observed, observed_at: now, freshness: :fresh, windows: %{"session" => window}}

    opts = [
      meter_views: %{claude: meter_view, codex: meter_view},
      github_quota: %{state: :observed, windows: %{core: window}},
      broker_usage: %{actors: [%{actor: "Executor", reserved: 2}]},
      ticket_usage: %{freshness: %{status: :fresh, observed_at: now}, totals: %{tokens: 12}}
    ]

    for provider <- ["claude", "codex", "github", "broker", "ticket"] do
      assert {:ok, record} = Aiur.Usage.provider(provider, opts)
      assert record["freshness"] == "fresh", provider
      refute is_nil(record["observed_at"]), provider
      assert map_size(record["fields"]) > 0, provider
    end
  end

  test "configured provider thresholds are bounded remaining percentages" do
    valid = Aiur.Config.Schema.Usage.changeset(%Aiur.Config.Schema.Usage{}, %{alerts: %{codex: %{threshold: 10}}})
    invalid = Aiur.Config.Schema.Usage.changeset(%Aiur.Config.Schema.Usage{}, %{alerts: %{codex: %{threshold: 101}}})
    assert valid.valid?
    refute invalid.valid?
  end

  test "provider and summary payloads share the usage contract" do
    summary = Aiur.Usage.json_snapshot(meter_views: %{}, github_quota: %{state: :unknown, windows: %{}}, broker_usage: %{actors: []}, ticket_usage: %{})
    assert summary["contract"] == "aiur.usage"
    assert summary["contract_version"] == 1
    assert Map.keys(summary["providers"]) |> Enum.sort() == Enum.map(Aiur.Usage.providers(), &Atom.to_string/1) |> Enum.sort()
    summary_text = CLI.render(summary, nil)
    assert summary_text =~ "PROVIDER  FRESHNESS  AGE       SOURCE"
    assert summary_text =~ "claude"
    assert summary_text =~ "github"

    assert {:ok, provider} = CLI.payload("codex", meter_views: %{})
    text = CLI.render(provider, "codex")
    assert text =~ "codex  unknown  unknown  provider_meter_projection"
  end

  test "each adapter returns its provider-specific read-model struct" do
    assert %Claude{provider: :claude} = Claude.read(meter_views: %{})
    assert %Codex{provider: :codex} = Codex.read(meter_views: %{})
    assert %GitHub{provider: :github} = GitHub.read(github_quota: %{state: :unknown, windows: %{}})
    assert %Broker{provider: :broker} = Broker.read(broker_usage: %{})
    assert %Ticket{provider: :ticket} = Ticket.read(ticket_usage: %{})
  end

  test "low usage emits once and resolves after recovery" do
    test_pid = self()

    emit = fn topic, opts ->
      send(test_pid, {topic, opts[:message]})
      :ok
    end

    state = Alerts.evaluate(:codex, 8, 10, MapSet.new(), emit)
    assert MapSet.member?(state, :codex)
    assert_received {"system.usage.codex.low", message}
    assert message =~ "8.0% remaining"

    state = Alerts.evaluate(:codex, 7, 10, state, emit)
    assert MapSet.member?(state, :codex)
    refute_received {"system.usage.codex.low", _message}

    state = Alerts.evaluate(:codex, 20, 10, state, emit)
    refute MapSet.member?(state, :codex)
    assert_received {"system.usage.codex.resolved", _message}
  end

  test "configured provider alert consumes observations and emits low then resolved" do
    test_pid = self()

    {:ok, alerts} =
      Alerts.start_link(
        name: nil,
        thresholds: %{codex: 10},
        emit: fn topic, opts ->
          send(test_pid, {topic, opts[:message]})
          :ok
        end
      )

    send(alerts, {:provider_meter_changed, meter_snapshot(92)})
    assert_receive {"system.usage.codex.low", "codex usage is at 8.0% remaining" <> _}, 1_000

    send(alerts, {:provider_meter_changed, meter_snapshot(70)})
    assert_receive {"system.usage.codex.resolved", "codex usage recovered to 30.0% remaining."}, 1_000

    GenServer.stop(alerts)
  end

  defp meter_snapshot(used_percent) do
    %Aiur.ProviderMeterSnapshot{
      provider: :codex,
      freshness: :fresh,
      windows: %{"session" => %{used_percent: used_percent}}
    }
  end
end
