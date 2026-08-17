defmodule AiurWeb.OperatorControlCenter.UnitsPresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsURL}
  alias AiurWeb.StreamDeckGrid

  test "loads typed provider snapshots once and keeps later projection pure" do
    test_pid = self()
    alpha = identity("NODE-alpha", "41")

    membership_fun = fn ->
      send(test_pid, :membership_read)
      membership([member(alpha)])
    end

    activity_fun = fn ->
      send(test_pid, :activity_read)

      %{
        generation: 8,
        entries: [
          %{
            identity: alpha,
            progress: %{status: :known, percent: 60, source: :checkin, freshness: %{status: :fresh}},
            latest_evidence: %{status: :known, source: :agent_event, occurred_at: ~U[2026-07-17 12:00:00Z]}
          }
        ]
      }
    end

    catalog = UnitsPresenter.load(payload(alpha), membership_fun: membership_fun, activity_fun: activity_fun)

    assert_received :membership_read
    assert_received :activity_read
    assert catalog.status == :ready

    assert [row] = catalog.snapshot.rows
    assert row.identity == alpha
    assert row.title == "Render Units"
    assert row.backend == "codex"
    assert row.agent_family == "codex"
    assert row.requested_model == "gpt-5.6"
    assert row.effort == "high"
    assert row.complexity == 3
    assert row.build_lane == "dashboard-ui"
    assert row.open_command_count == 2
    assert row.field_sources.open_command_count == :status_report
    assert row.provider_health.decisions == :degraded
    assert row.progress.percent == 60
    refute Map.has_key?(row, :workspace_path)

    view = UnitsPresenter.project(catalog, %{scope: :all, conditions: [:active, :alert]})

    assert view.selection == %{scope: :all, conditions: [:active, :alert]}
    assert view.rows == [row]
    assert view.counts.active == 1
    assert view.counts.alert == 1
    assert view.counts.scope == 1
    refute_received :membership_read
    refute_received :activity_read
  end

  test "current orchestrator rows prevent a healthy empty membership from reporting Active 0" do
    alpha = identity("NODE-restarted", "41")

    catalog =
      UnitsPresenter.load(payload(alpha),
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())

    assert catalog.status == :ready
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
    assert view.counts.active == 1
    refute UnitsPresenter.announcement(view) =~ "No units in this run yet"
  end

  test "provider failure is named unavailable instead of becoming a healthy empty catalog" do
    catalog =
      UnitsPresenter.load(%{},
        membership_fun: fn -> raise "membership down" end,
        activity_fun: fn -> exit(:activity_down) end
      )

    assert catalog.status == :unavailable
    assert catalog.message == "Fleet data is unavailable."
    assert catalog.snapshot.rows == []
    assert catalog.snapshot.health.membership == :unavailable
    assert catalog.snapshot.health.activity == :unavailable

    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())
    assert view.total_count == nil
    assert view.count_status == :unavailable
    assert Enum.all?(view.counts, fn {_name, count} -> is_nil(count) end)
    assert UnitsPresenter.announcement(view) =~ "No live units"
    refute UnitsPresenter.announcement(view) =~ "0 of 0"
  end

  test "unavailable membership with current agents reports unknown counts instead of zero" do
    alpha = identity("NODE-membership-unavailable", "41")

    catalog =
      UnitsPresenter.load(payload(alpha),
        membership_fun: fn -> raise "membership down" end,
        activity_fun: fn -> %{entries: []} end
      )

    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())

    assert catalog.status == :stale
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
    assert view.count_status == :partial
    assert view.counts.active == 1
    assert catalog.message == "Fleet data is unavailable."
  end

  test "truncated membership qualifies every catalog count as a lower bound" do
    identities = Enum.map(1..1_001, &identity("NODE-#{&1}", Integer.to_string(&1)))
    retained = identities |> Enum.take(1_000) |> Enum.map(&member/1)

    bounded_membership =
      retained
      |> membership()
      |> Map.put(:truncated?, length(identities) > length(retained))

    catalog =
      UnitsPresenter.load(%{},
        membership_fun: fn -> bounded_membership end,
        activity_fun: fn -> %{entries: []} end
      )

    view = UnitsPresenter.project(catalog, %{scope: :all, conditions: []})

    assert view.truncated?
    assert view.count_status == :partial
    assert view.total_count == 1_000
    assert view.counts.scope == 1_000
    assert UnitsPresenter.announcement(view) =~ "at least 1000 of at least 1000 Units"
  end

  test "same-count row changes produce a bounded production announcement revision" do
    alpha = identity("NODE-announcement", "41")
    catalog = UnitsPresenter.load(payload(alpha), membership_fun: fn -> membership([member(alpha)]) end)
    before = UnitsPresenter.project(catalog, %{scope: :all, conditions: []})

    updated_catalog = update_in(catalog, [:snapshot, :rows], fn [row] -> [%{row | title: "Updated title"}] end)
    after_update = UnitsPresenter.project(updated_catalog, %{scope: :all, conditions: []})

    assert before.total_count == after_update.total_count
    assert length(before.rows) == length(after_update.rows)
    refute before.revision == after_update.revision
    refute UnitsPresenter.announcement(before) == UnitsPresenter.announcement(after_update)
    assert UnitsPresenter.announcement(after_update) =~ ~r/Update [a-f0-9]{10}/
  end

  test "unknown membership health never renders as a healthy empty catalog" do
    catalog =
      UnitsPresenter.load(%{},
        membership_fun: fn -> %{members: [], health: :unknown, freshness: %{status: :unknown}} end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :unavailable
    assert catalog.message == "Fleet data is unavailable."
    assert catalog.snapshot.health.membership == :unknown
  end

  test "a stale fleet snapshot marks the catalog stale and names the age, not membership health" do
    alpha = identity("NODE-stale-fleet", "41")

    stale_payload =
      alpha
      |> payload()
      |> put_in([:fleet, :snapshot_freshness], %{status: :stale, reason: :snapshot_timeout, age_seconds: 342, observed_at: "2026-07-17T11:59:18Z"})

    catalog =
      UnitsPresenter.load(stale_payload,
        membership_fun: fn -> membership([member(alpha)]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :stale
    assert catalog.message =~ "Showing the units we last saw"
    assert catalog.message =~ "5m 42s ago"
    refute catalog.message =~ "membership is healthy"
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
  end

  # The Stream Deck projects a retained `:stale` snapshot unchanged, so the
  # Units catalog has to admit the same agents from the same snapshot. Before
  # this, any staleness dropped every status-sourced row and an operator with no
  # durable membership saw an empty Units page beside a full Stream Deck.
  test "a briefly stale fleet snapshot shows the same units the Stream Deck projects" do
    alpha = identity("NODE-parity-alpha", "41")
    beta = identity("NODE-parity-beta", "42")
    gamma = identity("NODE-parity-gamma", "43")

    fleet = %{
      running: [fleet_entry(alpha), fleet_entry(beta)],
      retrying: [],
      idle: [fleet_entry(gamma, work_state: :allocated, waiting_reason: :awaiting_dispatch)],
      snapshot_freshness: %{status: :stale, reason: :snapshot_timeout, age_seconds: 21, observed_at: "2026-07-17T11:59:39Z"}
    }

    catalog =
      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    deck = StreamDeckGrid.project(fleet)

    assert deck.total == 3
    assert length(catalog.snapshot.rows) == deck.total
    assert Enum.map(catalog.snapshot.rows, & &1.identity) == [alpha, beta, gamma]
  end

  test "a fleet snapshot stale beyond the shared window stops standing in for membership" do
    alpha = identity("NODE-aged-alpha", "41")

    fleet = %{
      running: [fleet_entry(alpha)],
      retrying: [],
      idle: [],
      snapshot_freshness: %{status: :stale, reason: :snapshot_stalled, age_seconds: 900, observed_at: "2026-07-17T11:45:00Z"}
    }

    catalog =
      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.snapshot.rows == []
    assert catalog.status == :stale
    assert catalog.message =~ "Fleet updates are running behind"
  end

  # The window is exclusive at its boundary, and both surfaces agree there: the
  # rows stop being a floor at exactly the age the catalog starts calling itself
  # stale, so neither can be right while the other is wrong.
  test "the shared staleness window closes at the same age for rows and for catalog status" do
    alpha = identity("NODE-boundary", "41")

    catalog = fn age_seconds ->
      fleet = %{
        running: [fleet_entry(alpha)],
        retrying: [],
        idle: [],
        snapshot_freshness: %{status: :stale, reason: :snapshot_timeout, age_seconds: age_seconds, observed_at: "2026-07-17T11:55:00Z"}
      }

      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )
    end

    assert length(catalog.(299).snapshot.rows) == 1
    assert catalog.(299).status == :ready
    assert catalog.(300).snapshot.rows == []
    assert catalog.(300).status == :stale
  end

  # An age-less `:stale` freshness cannot be judged against the window, so it
  # must not be admitted as a floor and must not read as a healthy catalog.
  test "a stale fleet view with no age is neither a row floor nor a ready catalog" do
    alpha = identity("NODE-ageless", "41")

    fleet = %{
      running: [fleet_entry(alpha)],
      retrying: [],
      idle: [],
      snapshot_freshness: %{status: :stale, reason: :snapshot_timeout, observed_at: "2026-07-17T11:55:00Z"}
    }

    catalog =
      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.snapshot.rows == []
    assert catalog.status == :stale
  end

  test "a fleet snapshot marked stale while still young is not presented as stale" do
    alpha = identity("NODE-fresh-fleet", "41")

    young_payload =
      alpha
      |> payload()
      |> put_in([:fleet, :snapshot_freshness], %{status: :stale, reason: :snapshot_timeout, age_seconds: 18, observed_at: "2026-07-17T11:59:42Z"})

    catalog =
      UnitsPresenter.load(young_payload,
        membership_fun: fn -> membership([member(alpha)]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :ready
    refute catalog.message
  end

  test "an unavailable fleet snapshot never reports a healthy membership as the reason" do
    alpha = identity("NODE-no-fleet", "41")

    unpublished_payload = %{
      generated_at: "2026-07-17T12:00:00Z",
      provider_health: %{fleet: :unavailable, decisions: :ok},
      fleet: %{error: %{code: "snapshot_unpublished", message: "No fleet snapshot published yet"}, running: [], retrying: [], idle: []},
      decisions: []
    }

    catalog =
      UnitsPresenter.load(unpublished_payload,
        membership_fun: fn -> membership([member(alpha)]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :stale
    assert catalog.message == "Showing the units we last saw. Fleet data is unavailable."
    refute catalog.message =~ "healthy"
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
  end

  test "a stale catalog with nothing retained does not claim to be showing a last-known-good catalog" do
    empty_fleet_payload = %{
      generated_at: "2026-07-17T12:00:00Z",
      provider_health: %{fleet: :unavailable, decisions: :ok},
      fleet: %{error: %{code: "snapshot_unpublished", message: "No fleet snapshot published yet"}, running: [], retrying: [], idle: []},
      decisions: []
    }

    catalog =
      UnitsPresenter.load(empty_fleet_payload,
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :stale
    assert catalog.snapshot.rows == []
    assert catalog.message == "No live units. Fleet data is unavailable."
    refute catalog.message =~ "Showing the units we last saw"
  end

  test "a reconciling membership is stale without claiming membership is healthy" do
    alpha = identity("NODE-reconciling", "41")

    reconciling = fn ->
      alpha |> List.wrap() |> Enum.map(&member/1) |> membership() |> Map.put(:freshness, %{status: :stale})
    end

    catalog = UnitsPresenter.load(payload(alpha), membership_fun: reconciling, activity_fun: fn -> %{entries: []} end)

    assert catalog.status == :stale
    assert catalog.message == "Showing the units we last saw. Still counting units for this run."
    refute catalog.message =~ "healthy"
  end

  test "selection helpers validate scopes and independently toggle conditions" do
    selection = UnitsURL.default_selection()

    selection = UnitsPresenter.select_scope(selection, "all")
    assert selection.scope == :all

    selection = UnitsPresenter.toggle_condition(selection, "paused")
    selection = UnitsPresenter.toggle_condition(selection, :alert)
    assert selection.conditions == [:alert, :paused]

    assert UnitsPresenter.toggle_condition(selection, "unknown") == selection
    assert UnitsPresenter.toggle_condition(selection, :paused).conditions == [:alert]
    assert UnitsPresenter.select_scope(selection, "invalid").scope == :live
  end

  test "bulk filter actions select every visible prior filter or none" do
    assert UnitsPresenter.select_all_filters() == %{
             scope: :unfinished,
             conditions: [:active, :alert, :paused, :queued, :finished]
           }

    assert UnitsPresenter.select_no_filters() == %{scope: :none, conditions: []}
  end

  test "row tokens are stable opaque server lookup keys" do
    alpha = identity("NODE-alpha-private", "41")
    catalog = UnitsPresenter.load(payload(alpha), membership_fun: fn -> membership([member(alpha)]) end, activity_fun: fn -> %{entries: []} end)
    [row] = catalog.snapshot.rows

    token = UnitsPresenter.row_token(row)

    assert is_binary(token)
    refute String.contains?(token, "NODE-alpha-private")
    assert {:ok, ^row} = UnitsPresenter.lookup(catalog, token)
    assert {:error, :not_found} = UnitsPresenter.lookup(catalog, token <> "changed")
  end

  defp payload(identity) do
    %{
      generated_at: "2026-07-17T12:00:00Z",
      provider_health: %{fleet: :ok, decisions: :ok},
      fleet: %{
        running: [
          %{
            tracker_identity: identity,
            state: "in-progress",
            title: "Render Units",
            url: "https://github.com/its-everdred/aiur/issues/41",
            backend: "codex",
            agent_family: "codex",
            requested_model: "gpt-5.6",
            effort: "high",
            complexity: 3,
            labels: ["complexity:3", "build-lane:dashboard-ui"],
            work_state: :working,
            waiting_reason: :active,
            open_decision_count: 2,
            open_decision_count_health: :available,
            runtime_seconds: 90,
            workspace_path: "/private/agent/workspace"
          }
        ],
        retrying: [],
        idle: []
      },
      decisions: [
        %{
          lifecycle: :recorded,
          ticket: %{identifier: "41", url: "https://github.com/its-everdred/aiur/issues/41"}
        }
      ]
    }
  end

  defp fleet_entry(identity, attrs \\ []) do
    %{
      identifier: identity.identifier,
      tracker_identity: identity,
      state: "in-progress",
      title: "Unit #{identity.identifier}",
      url: "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}",
      backend: "codex",
      agent_family: "codex",
      labels: [],
      work_state: Keyword.get(attrs, :work_state, :working),
      waiting_reason: Keyword.get(attrs, :waiting_reason, :active)
    }
  end

  defp membership(members) do
    %{
      generation: 7,
      health: :healthy,
      health_message: "current-run membership is healthy",
      freshness: %{status: :fresh},
      members: members,
      truncated?: false
    }
  end

  defp member(identity) do
    %{
      identity: identity,
      lifecycle: :running,
      terminal?: false,
      first_observed_at: ~U[2026-07-17 11:00:00Z],
      last_observed_at: ~U[2026-07-17 12:00:00Z]
    }
  end

  defp identity(provider_id, identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end
end
