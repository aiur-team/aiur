Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.MergedOpenTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.{PlannerFixture, Server, Store}
  alias Aiur.Config.Schema
  alias Aiur.Events.Exchange
  @topic "ticket.2.queue.attention.merged_issue_open"

  defmodule Boundary do
    def open_issue_labels(_age) do
      Agent.get(__MODULE__, fn s ->
        labels = %{"1" => %{labels: ["agent:queued"]}}
        if s.available, do: {:ok, if(s.open, do: Map.put(labels, "2", %{labels: []}), else: labels), s.now}, else: {:error, :offline}
      end)
    end

    def issue_closure(_id, _age), do: {:ok, %{open?: false, state_reason: "completed"}}
    def ticket_pull_request(_id), do: Agent.get(__MODULE__, &{:ok, &1.pr})
    def status(_ids), do: :unavailable
  end

  setup do
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    root = Aiur.TestSupport.tmp_root!("queue-merged-open")
    Application.put_env(:aiur, :decision_state_dir, root)
    owner = self()
    :ok = Exchange.subscribe(@topic <> ".#")

    on_exit(fn ->
      GenServer.call(Exchange, {:unsubscribe, @topic <> ".#", owner})

      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      File.rm_rf!(root)
    end)

    boundary = start_supervised!({Agent, fn -> %{now: 10_000, open: true, pr: nil, available: true} end})
    Process.register(boundary, Boundary)
    input = PlannerFixture.input() |> PlannerFixture.waiting()
    {:ok, document} = Store.load()
    :ok = Store.save(%{document | queues: [%{hd(input.queues) | id: "q-abcd", held: true}], items: [%{hd(input.items) | queue_id: "q-abcd"}], edges: input.edges})
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true, merged_open_grace_seconds: 60}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         claim_probe: Boundary,
         settings: {:ok, settings},
         clock: fn -> Agent.get(Boundary, & &1.now) end,
         schedule: fn server, message, _ -> send(owner, {:scheduled, server, message}) end}
      )

    assert :sys.get_state(pid).status == :running
    assert_received {:scheduled, ^pid, :tick}
    reconcile(pid)
    {:ok, pid: pid}
  end

  test "delivered merged PR starts grace, emits once, and closure resolves", %{pid: pid} do
    change(pr: %{merged?: true, state: :closed})
    reconcile(pid)
    assert :sys.get_state(pid).merged_at_ms == %{"2" => 10_000}
    change(now: 69_999)
    reconcile(pid)
    refute_received {:event, %{topic: @topic}}
    change(now: 70_000)
    reconcile(pid)
    assert_received {:event, %{topic: @topic, ticket: "2"}}
    assert {:ok, %{latches: [%{key: {:merged_issue_open, "2"}, emitted?: true}]}} = Store.load()
    assert hd(:sys.get_state(pid).projections).verdict == :waiting
    change(pr: nil, now: 80_000)
    reconcile(pid)
    refute_received {:event, %{topic: @topic}}
    change(open: false)
    reconcile(pid)
    resolved = @topic <> ".resolved"
    assert_received {:event, %{topic: ^resolved}}
    assert {:ok, %{latches: []}} = Store.load()
  end

  test "duplicate merge hints preserve first time and emit once without a deposit", %{pid: pid} do
    send(pid, {:event, %{topic: "ticket.2.pr.merged"}})
    reconcile(pid)
    change(now: 69_999)
    send(pid, {:event, %{topic: "ticket.2.pr.merged"}})
    reconcile(pid)
    refute_received {:event, %{topic: @topic}}
    change(now: 70_000)
    reconcile(pid)
    assert_received {:event, %{topic: @topic}}
    send(pid, {:event, %{topic: "ticket.2.pr.merged"}})
    reconcile(pid)
    refute_received {:event, %{topic: @topic}}
    assert :sys.get_state(pid).merged_at_ms == %{"2" => 10_000}
    refute {:attention_open, {:merged_issue_open, "2"}} in :sys.get_state(pid).actions
  end

  test "unknown issue observation keeps an opened attention until closure", %{pid: pid} do
    send(pid, {:event, %{topic: "ticket.2.pr.merged"}})
    reconcile(pid)
    change(now: 70_000)
    reconcile(pid)
    assert_received {:event, %{topic: @topic}}
    change(available: false, now: 80_000)
    reconcile(pid)
    resolved = @topic <> ".resolved"
    refute_received {:event, %{topic: ^resolved}}
    assert {:ok, %{latches: [%{key: {:merged_issue_open, "2"}}]}} = Store.load()
    change(available: true, open: false)
    reconcile(pid)
    assert_received {:event, %{topic: ^resolved}}
  end

  test "closing within grace never opens an attention (future closure regression guard)", %{pid: pid} do
    send(pid, {:event, %{topic: "ticket.2.pr.merged"}})
    reconcile(pid)
    change(now: 20_000, open: false)
    reconcile(pid)
    change(now: 80_000)
    reconcile(pid)
    refute_received {:event, %{topic: @topic}}
    assert {:ok, %{latches: []}} = Store.load()
    assert hd(:sys.get_state(pid).projections).verdict == :ready
  end

  defp change(changes), do: Agent.update(Boundary, &Enum.into(changes, &1))

  defp reconcile(pid) do
    :ok = GenServer.call(pid, :reconcile_now)
    assert_received {:scheduled, ^pid, message}
    send(pid, message)
    GenServer.call(pid, :show)
  end
end
