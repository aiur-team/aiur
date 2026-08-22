defmodule AiurWeb.StreamDeckGridTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.StreamDeckGrid

  test "projects an empty fleet" do
    assert StreamDeckGrid.project(%{running: [], retrying: [], idle: []}) == %{
             agents: [],
             total: 0,
             columns_per_page: 4,
             rows_per_column: 2,
             agents_per_page: 8,
             windows: 0,
             max_column_offset: 0
           }
  end

  test "tolerates an incomplete snapshot" do
    assert StreamDeckGrid.project(%{}).agents == []
  end

  test "projects unavailable snapshots as API errors" do
    assert StreamDeckGrid.payload(:missing_streamdeck_orchestrator, 1) == %{
             error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
           }
  end

  test "projects a completed snapshot from the read model" do
    server = start_supervised!({__MODULE__.TimeoutServer, []})

    :ok = SnapshotStore.publish(server, %{running: [], retrying: [], idle: []})

    assert %{agents: [], snapshot_freshness: %{status: :current}} = StreamDeckGrid.payload(server, 1)
  end

  test "returns a hard error before the first snapshot" do
    server = start_supervised!({__MODULE__.TimeoutServer, []})

    assert StreamDeckGrid.payload(server, 0) == %{
             error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
           }
  end

  test "projects fewer than eight agents with the column-major contract metadata" do
    payload = StreamDeckGrid.project(%{running: [agent("1"), agent("2")], retrying: [], idle: [agent("3")]})

    assert payload.total == 3
    assert payload.windows == 1
    assert payload.max_column_offset == 0
    assert Enum.map(payload.agents, & &1.identifier) == ["1", "2", "3"]
  end

  test "projects the design paging metadata for twenty filtered agents" do
    agents = Enum.map(1..20, &agent(to_string(&1)))
    payload = StreamDeckGrid.project(%{running: agents, retrying: [], idle: []})

    assert payload.total == 20
    assert payload.windows == 3
    assert payload.max_column_offset == 6
  end

  test "uses canonical ticket ordering within equal ranks" do
    payload = StreamDeckGrid.project(%{running: [agent("10"), agent("2")], retrying: [], idle: []})

    assert Enum.map(payload.agents, & &1.identifier) == ["2", "10"]
  end

  test "sorts one agent per bucket and places dependency-ready queued work first" do
    payload =
      StreamDeckGrid.project(%{
        running: [agent("running"), agent("paused", work_state: :paused), agent("alert", open_decision_count: 1), agent("stuck", work_state: :error)],
        retrying: [],
        idle: [
          agent("queued-blocked", blocked_by: [%{id: "missing-upstream"}]),
          agent("queued-ready", blocked_by: [])
        ]
      })

    assert Enum.map(payload.agents, & &1.identifier) == [
             "alert",
             "stuck",
             "running",
             "paused",
             "queued-ready",
             "queued-blocked"
           ]

    assert Enum.map(Enum.take(payload.agents, 4), & &1.bucket) == [
             :alert,
             :stuck,
             :running,
             :paused
           ]

    assert Enum.map(Enum.drop(payload.agents, 4), &{&1.identifier, &1.dependency_ready}) == [
             {"queued-ready", true},
             {"queued-blocked", false}
           ]
  end

  test "puts a stuck agent from the raw fleet tail on the first page" do
    payload =
      StreamDeckGrid.project(%{
        running: Enum.map(1..8, &agent("running-#{&1}")) ++ [agent("stuck-tail", work_state: :error)],
        retrying: [],
        idle: []
      })

    assert payload.agents |> Enum.take(8) |> Enum.map(& &1.identifier) |> List.first() == "stuck-tail"
  end

  test "uses the injected readiness predicate to rank queued agents" do
    payload =
      StreamDeckGrid.project(
        %{running: [], retrying: [], idle: [agent("blocked"), agent("ready")]},
        fn entry -> entry.identifier == "ready" end
      )

    assert Enum.map(payload.agents, &{&1.identifier, &1.dependency_ready}) == [
             {"ready", true},
             {"blocked", false}
           ]
  end

  test "tracker-unavailable queued work is stuck rather than ready" do
    payload =
      StreamDeckGrid.project(%{
        running: [],
        retrying: [],
        idle: [agent("tracker-held", waiting_reason: :tracker_unavailable)]
      })

    assert [%{identifier: "tracker-held", bucket: :stuck} = held] = payload.agents
    refute Map.has_key?(held, :dependency_ready)
  end

  test "omits idle tickets whose dispatch was declined" do
    payload =
      StreamDeckGrid.project(%{
        running: [],
        retrying: [],
        idle: [
          agent("queued"),
          agent("decision-blocked", dispatch_decline_reason: :blocked_on_decision)
        ]
      })

    assert Enum.map(payload.agents, & &1.identifier) == ["queued"]
  end

  test "derives queued readiness from complete fleet dependencies" do
    snapshot = %{
      running: [
        agent("open-upstream", progress_percent: 99),
        agent("merged-upstream", control: "Merged"),
        agent("complete-upstream", progress_percent: 100)
      ],
      retrying: [],
      idle: [
        agent("open-child", blocked_by: [%{id: "open-upstream"}]),
        agent("merged-child", blocked_by: [%{id: "merged-upstream"}]),
        agent("complete-child", blocked_by: [%{id: "complete-upstream"}]),
        agent("unknown-child", blocked_by: [%{id: "absent-upstream"}]),
        agent("independent-child", blocked_by: []),
        agent("missing-data-child"),
        agent("unresolved-child", blocked_by: nil)
      ]
    }

    readiness =
      snapshot
      |> StreamDeckGrid.project()
      |> Map.fetch!(:agents)
      |> Enum.filter(&(&1.bucket == :queued))
      |> Map.new(&{&1.identifier, &1.dependency_ready})

    assert readiness == %{
             "open-child" => false,
             "merged-child" => true,
             "complete-child" => true,
             "unknown-child" => false,
             "independent-child" => true,
             "missing-data-child" => false,
             "unresolved-child" => false
           }
  end

  property "renders agents in non-decreasing Stream Deck rank for any fleet" do
    check all(bucket_sequence <- list_of(member_of([:alert, :stuck, :running, :paused, :queued]), max_length: 40), max_runs: 30) do
      snapshot = snapshot_for(bucket_sequence)

      ranks =
        snapshot
        |> StreamDeckGrid.project()
        |> Map.fetch!(:agents)
        |> Enum.map(&bucket_rank(&1.bucket))

      assert ranks == Enum.sort(ranks)
    end
  end

  test "keeps equal-rank agents stable when snapshot order changes" do
    first_snapshot = %{running: [agent("10"), agent("2")], retrying: [], idle: []}
    second_snapshot = %{running: [agent("2"), agent("10")], retrying: [], idle: []}

    assert Enum.map(StreamDeckGrid.project(first_snapshot).agents, & &1.identifier) == ["2", "10"]
    assert Enum.map(StreamDeckGrid.project(second_snapshot).agents, & &1.identifier) == ["2", "10"]
  end

  test "includes the Stream Deck agent fields" do
    [agent] = StreamDeckGrid.project(%{running: [agent("123", backend: "claude", progress_percent: 60, priority: 1)], retrying: [], idle: []}).agents

    assert agent == %{
             identifier: "123",
             title: "Ticket 123",
             icon: :unassigned,
             vendor: "claude",
             vendor_logo: "/provider-assets/claude-symbol.svg",
             bucket: :running,
             progress_percent: 60,
             progress_freshness: "fresh",
             priority: true,
             activity: nil,
             runtime_seconds: nil
           }
  end

  test "projects the workflow stage as the agent's activity" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("123", activity_stage: :review, runtime_seconds: 4_320)],
        retrying: [],
        idle: []
      }).agents

    assert agent.activity == "review"
    assert agent.runtime_seconds == 4_320
  end

  test "prefers an actionable wait over the stage it parked in" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("123", activity_stage: :work, waiting_reason: :waiting_for_ci)],
        retrying: [],
        idle: []
      }).agents

    assert agent.activity == "waiting_ci"
  end

  test "omits activity for a wait the bucket already carries and for an unknown stage" do
    [paused] =
      StreamDeckGrid.project(%{
        running: [agent("123", waiting_reason: :paused_operator, work_state: :paused)],
        retrying: [],
        idle: []
      }).agents

    [unknown] =
      StreamDeckGrid.project(%{running: [agent("124", activity_stage: :sprinting)], retrying: [], idle: []}).agents

    assert paused.activity == nil
    assert unknown.activity == nil
  end

  test "reports an absent or zero runtime as unknown rather than as no time elapsed" do
    [absent] = StreamDeckGrid.project(%{running: [agent("123")], retrying: [], idle: []}).agents
    [zero] = StreamDeckGrid.project(%{running: [agent("124", runtime_seconds: 0)], retrying: [], idle: []}).agents

    assert absent.runtime_seconds == nil
    assert zero.runtime_seconds == nil
  end

  test "normalizes vendor and invalid activity values" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("123", agent_family: "claude", backend: "codex", progress_percent: 101, priority: "high")],
        retrying: [],
        idle: []
      }).agents

    assert agent.vendor == "claude"
    assert agent.progress_percent == nil
    assert agent.progress_freshness == "unknown"
    refute agent.priority
  end

  test "keeps a stale reading instead of replacing it with a zero nobody measured" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("123", progress_percent: 70, progress_freshness: :stale)],
        retrying: [],
        idle: []
      }).agents

    assert agent.progress_percent == 70
    assert agent.progress_freshness == "stale"
  end

  test "reports an unmeasured ticket as unknown rather than as no progress" do
    [absent] = StreamDeckGrid.project(%{running: [agent("123")], retrying: [], idle: []}).agents

    [declared] =
      StreamDeckGrid.project(%{
        running: [agent("124", progress_percent: nil, progress_freshness: :unknown)],
        retrying: [],
        idle: []
      }).agents

    assert absent.progress_percent == nil
    assert absent.progress_freshness == "unknown"
    assert declared.progress_percent == nil
    assert declared.progress_freshness == "unknown"
  end

  test "a measured zero stays a measured zero" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("123", progress_percent: 0, progress_freshness: :fresh)],
        retrying: [],
        idle: []
      }).agents

    assert agent.progress_percent == 0
    assert agent.progress_freshness == "fresh"
  end

  test "rounds a float reading rather than discarding it" do
    [agent] =
      StreamDeckGrid.project(%{running: [agent("123", progress_percent: 70.5)], retrying: [], idle: []}).agents

    assert agent.progress_percent == 71
    assert agent.progress_freshness == "fresh"
  end

  test "never pairs a nil percent with a confident freshness" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("123", progress_percent: nil, progress_freshness: :fresh)],
        retrying: [],
        idle: []
      }).agents

    assert agent.progress_percent == nil
    assert agent.progress_freshness == "unknown"
  end

  test "unknown upstream progress blocks a dependent rather than reading as complete" do
    snapshot = %{
      running: [
        agent("unknown-upstream", progress_percent: nil, progress_freshness: :unknown),
        agent("stale-complete-upstream", progress_percent: 100, progress_freshness: :stale)
      ],
      retrying: [],
      idle: [
        agent("child-of-unknown", blocked_by: [%{id: "unknown-upstream"}]),
        agent("child-of-stale-complete", blocked_by: [%{id: "stale-complete-upstream"}])
      ]
    }

    readiness =
      snapshot
      |> StreamDeckGrid.project()
      |> Map.fetch!(:agents)
      |> Enum.filter(&(&1.bucket == :queued))
      |> Map.new(&{&1.identifier, &1.dependency_ready})

    assert readiness == %{"child-of-unknown" => false, "child-of-stale-complete" => true}
  end

  test "projects a registry provider family without coercing it to codex" do
    [agent] =
      StreamDeckGrid.project(%{running: [agent("1439", backend: "fake")], retrying: [], idle: []}).agents

    assert agent.vendor == "fake"
    assert agent.vendor_logo == "/provider-assets/codex-color.svg"
  end

  test "projects the Build Order lane icon and provider logo from source metadata" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("1439", backend: "deepseek", labels: ["build-lane:platform"])],
        retrying: [],
        idle: []
      }).agents

    assert agent.icon == "platform"
    assert agent.vendor == "deepseek"
    assert agent.vendor_logo == "/provider-assets/deepseek.svg"
  end

  test "only flags positive priority ranks" do
    agents = StreamDeckGrid.project(%{running: [agent("1", priority: 0), agent("2", priority: 1)], retrying: [], idle: []}).agents
    unprioritized = Enum.find(agents, &(&1.identifier == "1"))
    prioritized = Enum.find(agents, &(&1.identifier == "2"))

    refute unprioritized.priority
    assert prioritized.priority
  end

  test "places prioritized agents first within their Stream Deck bucket" do
    payload =
      StreamDeckGrid.project(%{
        running: [agent("normal"), agent("priority-two", priority: 2), agent("priority-one", priority: 1)],
        retrying: [],
        idle: []
      })

    assert Enum.map(payload.agents, & &1.identifier) == ["priority-one", "priority-two", "normal"]
  end

  defp agent(identifier, attrs \\ []) do
    Map.merge(
      %{
        identifier: identifier,
        title: "Ticket #{identifier}",
        backend: "codex",
        work_state: :working,
        open_decision_count: 0,
        waiting_reason: :active,
        tracker_paused: false,
        priority: nil
      },
      Map.new(attrs)
    )
  end

  defp snapshot_for(bucket_sequence) do
    bucket_sequence
    |> Enum.with_index()
    |> Enum.reduce(%{running: [], retrying: [], idle: []}, fn {bucket, index}, snapshot ->
      entry = agent("agent-#{index}")

      case bucket do
        :alert -> Map.update!(snapshot, :running, &(&1 ++ [Map.put(entry, :open_decision_count, 1)]))
        :stuck -> Map.update!(snapshot, :running, &(&1 ++ [Map.put(entry, :work_state, :error)]))
        :running -> Map.update!(snapshot, :running, &(&1 ++ [entry]))
        :paused -> Map.update!(snapshot, :running, &(&1 ++ [Map.put(entry, :work_state, :paused)]))
        :queued -> Map.update!(snapshot, :idle, &(&1 ++ [entry]))
      end
    end)
  end

  defp bucket_rank(:alert), do: 0
  defp bucket_rank(:stuck), do: 1
  defp bucket_rank(:running), do: 2
  defp bucket_rank(:paused), do: 3
  defp bucket_rank(:queued), do: 4

  defmodule TimeoutServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

    def child_spec(opts), do: %{id: {__MODULE__, Keyword.get(opts, :name, self())}, start: {__MODULE__, :start_link, [opts]}}

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:noreply, state}
  end
end
