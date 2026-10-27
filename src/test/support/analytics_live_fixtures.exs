defmodule AiurWeb.AnalyticsLiveFixtures do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import Aiur.TestSupport.UsageAggregate, only: [envelope: 0, record: 3]
  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.Orchestrator.{SnapshotCache, SnapshotStore}
  alias Aiur.{RunTelemetry, TrackerIdentity}
  alias Aiur.TestSupport.{AwaitingCommands, EndpointStubs, LiveViewAsync}
  alias Aiur.UsageAggregate.Projection
  alias AiurWeb.Endpoint
  @endpoint Endpoint
  @summary_fixture Path.expand("../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)
  defmodule UsageAggregateSourceStub do
    @moduledoc false
    def cells_snapshot,
      do: Application.fetch_env!(:aiur, :analytics_usage_aggregate_source_snapshot)

    def snapshot, do: cells_snapshot().metadata
  end

  defmodule BuildOrderSourceStub do
    @moduledoc false

    def catalog(context), do: context.catalog

    def demand(context, identity) do
      case Map.fetch(context.selected, identity.identifier) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> {:error, :unavailable}
      end
    end
  end

  def setup_analytics(context) do
    previous_telemetry = Application.get_env(:aiur, :analytics_telemetry_file)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    orchestrator = {:global, {context.module, context.test}}

    if capacity = Map.get(context, :analytics_capacity) do
      # A publisher has to be alive under the orchestrator's registered name, or
      # every read is `:orchestrator_unavailable` — a retained-cache state, not
      # the live one these tests are about.
      publisher = start_supervised!({Agent, fn -> :ok end})
      :yes = :global.register_name({context.module, context.test}, publisher)

      SnapshotStore.publish(orchestrator, %{capacity: capacity})

      if age_ms = Map.get(context, :analytics_capacity_age_ms) do
        # Pin the ceiling: it otherwise derives from the effective poll cadence,
        # so a test that asked the code for its own ceiling would pass against
        # one wide enough that staleness is never reported at all.
        previous_ceiling = Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms)
        Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, 120_000)
        on_exit(fn -> reset_env(:snapshot_stale_age_ceiling_ms, previous_ceiling) end)

        age_published_snapshot(orchestrator, age_ms)
      end
    end

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        orchestrator: orchestrator
      )
      |> Keyword.merge(awaiting_commands_config(context))

    Application.put_env(:aiur, Endpoint, EndpointStubs.scope(endpoint_config))
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      SnapshotStore.forget(orchestrator)
      reset_env(Endpoint, previous_endpoint)
      reset_env(:analytics_telemetry_file, previous_telemetry)
    end)

    :ok
  end

  def write_newer_summary!(path) do
    summary = @summary_fixture |> File.read!() |> String.replace("930", "999") |> Jason.decode!()

    newer =
      summary
      |> put_in(["provenance", "time_range", "end"], "2026-07-12T00:00:16Z")

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(newer))
  end

  # Dashboard routes are behind the FinancialDataAccess plug, which challenges
  # any request once credentials are configured (regardless of `dashboard_auth_required`).
  # test_helper configures credentials globally, so every analytics render test must
  # present them. Tests that exercise the missing-configuration path build their own
  # unauthenticated conn explicitly.
  def loaded_live(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, LiveViewAsync.render_when_complete(view)}
  end

  def build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
  end

  def reset_env(key, nil), do: Application.delete_env(:aiur, key)
  def reset_env(key, value), do: Application.put_env(:aiur, key, value)

  def restore_run_id(:unset), do: :persistent_term.erase({Aiur.Boot, :run_id})
  def restore_run_id(value), do: :persistent_term.put({Aiur.Boot, :run_id}, value)

  def complexity_fixture! do
    root = Aiur.TestSupport.tmp_root!("aiur-analytics-complexity")

    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      record(1, "restart", ~U[2026-07-11 00:00:00Z], %{}),
      record(2, "dispatch", ~U[2026-07-11 00:00:01Z], %{"complexity" => 1}),
      record(3, "pr_merged", ~U[2026-07-11 00:01:01Z], %{}),
      record(4, "dispatch", ~U[2026-07-11 00:02:01Z], %{"complexity" => 3}),
      record(5, "pr_merged", ~U[2026-07-11 00:04:01Z], %{})
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file]) end)
    path
  end

  def route_fixture!(current_boot_id) do
    root =
      Aiur.TestSupport.tmp_root!("aiur-analytics-route")

    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      route_record("prior-boot", 1, "restart", ~U[2026-07-11 00:00:00Z], nil),
      route_record("prior-boot", 2, "pr_merged", ~U[2026-07-11 00:00:01Z], "940"),
      route_record(current_boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], nil),
      route_record(current_boot_id, 2, "dispatch", ~U[2026-07-11 00:01:01Z], "941"),
      route_record(current_boot_id, 3, "pr_opened", ~U[2026-07-11 00:01:02Z], "941"),
      route_record(current_boot_id, 4, "pr_merged", ~U[2026-07-11 00:01:03Z], "941")
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file]) end)
    path
  end

  def route_record(boot_id, sequence, event, timestamp, ticket) do
    attributes =
      %{
        "event" => event,
        "boundary" => "point",
        "event_key" => "route-#{boot_id}-#{sequence}"
      }
      |> then(fn attributes ->
        if ticket, do: Map.put(attributes, "ticket", ticket), else: attributes
      end)

    %{
      schema_version: 2,
      kind: if(event == "restart", do: "restart", else: "lifecycle"),
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: boot_id,
      sequence: sequence,
      record_id: "#{boot_id}:#{sequence}",
      attributes: attributes
    }
  end

  def provider_spend_snapshot(member \\ nil, non_member \\ nil, prior_session_member \\ nil, member_run_id \\ nil) do
    member = member || identity(941, "NODE-941")

    member_envelope =
      envelope()
      |> Map.put(:attribution, attribution(member, member_run_id || RunTelemetry.boot_id()))

    projection = Projection.apply_record(Projection.new(), record(1, member_envelope, %{cost: "3.50"}))

    projection =
      if non_member do
        non_member_envelope = envelope() |> Map.put(:attribution, attribution(non_member))
        Projection.apply_record(projection, record(2, non_member_envelope, %{cost: "9.99"}))
      else
        projection
      end

    projection =
      if prior_session_member do
        prior_session_envelope = envelope() |> Map.put(:attribution, attribution(prior_session_member, "earlier-run"))
        Projection.apply_record(projection, record(3, prior_session_envelope, %{cost: "11.00"}))
      else
        projection
      end

    %{
      cells: projection.cells,
      metadata: %{
        generation: projection.generation,
        health: :healthy,
        freshness: %{status: :fresh},
        retained_interval: %{earliest: 1, latest: 1, status: :retained}
      }
    }
  end

  defp attribution(identity, run_id \\ RunTelemetry.boot_id()) do
    %{
      run_id: run_id,
      tracker_identity: identity,
      attempt_id: "attempt-1",
      session_id: "session-1",
      thread_id: "thread-1",
      turn_id: "turn-1",
      request_id: "request-1"
    }
  end

  # `publish/2` stamps the current monotonic clock, so restating the observation
  # time is the only way to read a ten-minute-old snapshot without waiting.
  defp age_published_snapshot(orchestrator, age_ms) do
    cached = SnapshotCache.get(orchestrator)

    SnapshotCache.put(
      orchestrator,
      %{
        cached
        | observed_at_ms: System.monotonic_time(:millisecond) - age_ms,
          observed_at: DateTime.add(DateTime.utc_now(), -age_ms, :millisecond),
          recent_gaps_ms: []
      }
    )

    :ok
  end

  def build_order_context(root, member) do
    health = ProviderHealth.new(1, :healthy, true)

    root_summary =
      RootSummary.new(%{
        identity: root,
        title: "Analytics Build",
        url: "https://github.com/owner/repo/issues/#{root.identifier}"
      })

    selected =
      %Snapshot{
        scope: {:selected, root},
        repository: {"owner", "repo"},
        authority_epoch: 1,
        generation: 1,
        data:
          SelectedRoot.new(
            root_summary,
            [
              Member.new(%{
                identity: member,
                title: "Selected member",
                url: "https://github.com/owner/repo/issues/#{member.identifier}"
              })
            ],
            health
          ),
        health: health
      }

    %{
      catalog: %Snapshot{
        scope: :catalog,
        repository: {"owner", "repo"},
        authority_epoch: 1,
        generation: 1,
        data: Catalog.new([root_summary], health),
        health: health
      },
      selected: %{root.identifier => selected}
    }
  end

  def identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "database_id" => number, "number" => number},
        {"owner", "repo"},
        {"owner", "repo"}
      )

    identity
  end

  def build_order_route_fixture!(current_boot_id) do
    root = Aiur.TestSupport.tmp_root!("aiur-analytics-build-order")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      route_record(current_boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], nil),
      route_record(current_boot_id, 2, "dispatch", ~U[2026-07-11 00:01:01Z], "941"),
      route_record(current_boot_id, 3, "pr_opened", ~U[2026-07-11 00:01:02Z], "941"),
      route_record(current_boot_id, 4, "pr_merged", ~U[2026-07-11 00:01:03Z], "941"),
      route_record(current_boot_id, 5, "dispatch", ~U[2026-07-11 00:01:04Z], "942"),
      route_record(current_boot_id, 6, "pr_opened", ~U[2026-07-11 00:01:05Z], "942"),
      route_record(current_boot_id, 7, "pr_merged", ~U[2026-07-11 00:01:06Z], "942")
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file]) end)
    path
  end

  defp record(sequence, event, timestamp, extra) do
    %{
      schema_version: 2,
      kind: "lifecycle",
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: "complexity-boot",
      sequence: sequence,
      record_id: "complexity-boot:#{sequence}",
      attributes:
        Map.merge(
          %{
            "ticket" => if(sequence in [2, 3], do: "1", else: "3"),
            "attempt_id" => "attempt-#{sequence}",
            "event" => event,
            "boundary" => "point",
            "event_key" => "complexity-#{sequence}"
          },
          extra
        )
    }
  end

  defp awaiting_commands_config(context) do
    case context[:awaiting_commands] do
      nil -> []
      counts -> [decision_store: AwaitingCommands.start(counts)]
    end
  end
end
