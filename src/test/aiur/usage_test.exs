defmodule Aiur.UsageTest do
  use ExUnit.Case, async: true
  alias Aiur.Usage.Alerts
  alias Aiur.Usage.CLI
  alias Aiur.Usage.Events
  alias Aiur.Usage.Provider.{Broker, Claude, Codex, GitHub, Ticket}

  test "registry includes the Netlify provider adapter" do
    assert Enum.sort(Aiur.Usage.providers()) == [:broker, :claude, :codex, :github, :netlify, :ticket]
    assert {:ok, %{"provider" => "netlify"}} = Aiur.Usage.provider("netlify", netlify_usage: %{provider: :netlify, state: :unavailable, reason: :disabled, freshness: :unavailable, fields: %{}})
  end

  test "every unavailable provider remains unknown instead of becoming zero" do
    cases = [
      {"claude", [meter_views: %{}]},
      {"codex", [meter_views: %{}]},
      {"github", [github_quota: %{state: :unknown, windows: %{}}]},
      {"broker", [broker_usage: %{}]},
      {"ticket", [ticket_usage: %{}]},
      {"netlify", [netlify_usage: %{provider: :netlify, state: :unavailable, reason: :disabled, freshness: :unknown, fields: %{}}]}
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

  test "Netlify balance remains unavailable when audit data has no known balance" do
    now = ~U[2026-10-25 12:00:00Z]

    data = %{
      account: %{"plan_credits" => 500, "current_billing_period_start" => "2026-10-01T00:00:00Z"},
      audit: [%{"action" => "Credits purchased", "created_at" => "2026-10-24T12:00:00Z", "traits" => %{"purchase_amount" => 500}}],
      sites: [],
      bandwidth: %{}
    }

    result = Aiur.Netlify.Usage.calculate(data, now)
    assert result.state == :unavailable
    assert result.credits.estimated_remaining == nil
    refute is_number(result.credits.estimated_remaining)
  end

  test "Netlify estimate subtracts deploy and bandwidth burn since its audit anchor" do
    now = ~U[2026-10-25 12:00:00Z]

    data = %{
      account: %{"plan_credits" => 500, "current_billing_period_start" => "2026-10-01T00:00:00Z"},
      audit: [%{"action" => "Account notified of credit balance threshold", "created_at" => "2026-10-24T12:00:00Z", "traits" => %{"credit_balance" => 250}}],
      sites: [%{id: "site-1", name: "Main", production_deploys: 2}],
      bandwidth: %{"total" => 1_000_000_000}
    }

    result = Aiur.Netlify.Usage.calculate(data, now)
    assert_in_delta result.credits.estimated_remaining, 250 - 50 / 24.5, 0.001
    assert result.credits.anchor_age_seconds == 86_400
    assert hd(result.sites).credits_burn == 30
    assert result.credits.runway_days > 0
  end

  test "Netlify purchase delta extends only an existing audit balance anchor" do
    now = ~U[2026-10-25 12:00:00Z]

    data = %{
      account: %{"current_billing_period_start" => "2026-10-01T00:00:00Z"},
      audit: [
        %{"action" => "Account notified of credit balance threshold", "created_at" => "2026-10-22T12:00:00Z", "traits" => %{"credit_balance" => 250}},
        %{"action" => "Credits purchased", "created_at" => "2026-10-23T12:00:00Z", "traits" => %{"purchase_amount" => 500}}
      ],
      sites: [],
      bandwidth: %{}
    }

    assert Aiur.Netlify.Usage.calculate(data, now).credits.anchor_balance == 750
  end

  test "Netlify alert opens on audit threshold and resolves on a healthy estimate" do
    owner = self()

    emit = fn event ->
      send(owner, event)
      :ok
    end

    low = %{low_event?: true, fields: %{credits: %{estimated_remaining: 200}}}
    healthy = %{fields: %{credits: %{estimated_remaining: 250}}}
    assert Aiur.Netlify.Usage.alert_transition(low, 100, false, emit)
    assert_receive :low, 1_000
    refute Aiur.Netlify.Usage.alert_transition(healthy, 100, true, emit)
    assert_receive :resolved, 1_000
  end

  test "Netlify alert opens when estimated credits cross the configured threshold" do
    owner = self()

    emit = fn event ->
      send(owner, event)
      :ok
    end

    below_threshold = %{fields: %{credits: %{estimated_remaining: 99}}}

    assert Aiur.Netlify.Usage.alert_transition(below_threshold, 100, false, emit)
    assert_receive :low, 1_000
    refute Aiur.Netlify.Usage.alert_transition(below_threshold, 0, false, emit)
    refute_receive :low, 20
  end

  test "Netlify CLI JSON uses the shared envelope and labels an unavailable balance" do
    snapshot = %{
      provider: :netlify,
      state: :unavailable,
      reason: :no_valid_audit_anchor,
      observed_at: ~U[2026-10-25 12:00:00Z],
      age_ms: 17,
      freshness: :unavailable,
      fields: %{credits: %{estimated_remaining: nil}}
    }

    assert {:ok, payload} = CLI.payload("netlify", netlify_usage: snapshot)
    assert payload["contract"] == "aiur.usage"
    assert payload["contract_version"] == 1
    assert payload["provider"]["age_ms"] == 17
    assert payload["provider"]["fields"]["credits"]["estimated_remaining"] == nil
    assert CLI.render(payload, "netlify") =~ "estimated credits: unavailable"
  end

  test "Netlify alert handler emits the low and resolved system topics" do
    owner = self()

    {:ok, _server} =
      Alerts.start_link(
        name: nil,
        emit: fn topic, _opts ->
          send(owner, topic)
          :ok
        end
      )

    Events.broadcast_netlify(%{low_event?: true, fields: %{credits: %{estimated_remaining: 20}}})
    assert_receive "system.netlify.credits_low", 1_000
    Events.broadcast_netlify(%{fields: %{credits: %{estimated_remaining: 200}}})
    assert_receive "system.netlify.credits_low.resolved", 1_000
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

  test "stale and unknown snapshots do not trigger usage alerts" do
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

    for freshness <- [:stale, :unknown] do
      send(alerts, {:provider_meter_changed, meter_snapshot(99, freshness)})
      refute_receive {"system.usage.codex.low", _message}, 50
      refute_receive {"system.usage.codex.resolved", _message}, 50
    end

    GenServer.stop(alerts)
  end

  defp meter_snapshot(used_percent, freshness \\ :fresh) do
    %Aiur.ProviderMeterSnapshot{
      provider: :codex,
      freshness: freshness,
      windows: %{"session" => %{used_percent: used_percent}}
    }
  end
end
