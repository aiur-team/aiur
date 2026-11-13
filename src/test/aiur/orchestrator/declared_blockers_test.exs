defmodule Aiur.Orchestrator.DeclaredBlockersTest do
  # A worker's sibling "I'll integrate their work later" declaration once paused it and
  # held re-dispatch until the sibling merged, stalling a feature mid-build. These tests
  # pin that a declared link stays advisory until the Executor confirms it.
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Hints
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.ControlCLI.Blocker
  alias Aiur.JsonStore
  alias Aiur.Orchestrator.{DeclaredBlockers, DispatchPolicy, PushRouting, State}

  setup do
    root = Aiur.TestSupport.tmp_root!("declared-blockers")
    path = Path.join(root, "declared-blockers.json")
    previous = Application.get_env(:aiur, :declared_blockers_path)
    Application.put_env(:aiur, :declared_blockers_path, path)
    if :ets.whereis(Hints.table_name()) == :undefined, do: :ets.new(Hints.table_name(), [:named_table, :set])

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :declared_blockers_path, previous), else: Application.delete_env(:aiur, :declared_blockers_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{path: path, terminal: DispatchPolicy.terminal_state_set()}
  end

  describe "dependency pause request" do
    setup do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.741.dependency.declared_blocker")
      on_exit(fn -> for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern) end)
    end

    test "an unconfirmed declared link keeps the worker running and alerts the Executor" do
      declare("741", "739")
      assert_receive {:event, %{"needs_attention" => true, topic: "ticket.741.dependency.declared_blocker"}}, 500

      result = PushRouting.maybe_pause_on_request(state(), "741", dependency_pause("739"))

      assert result.running["issue-741"].control.status == :working
      refute Map.has_key?(result.running["issue-741"], :paused_reason)
      assert_receive {:event, %{"needs_attention" => true, "message" => message}}, 500
      assert message == "#741 declared #739 as a blocker; confirm to hold #741 until #739 merges"
    end

    test "a confirmed declared link pauses for the blocker as before" do
      declare("741", "739")
      assert :ok = DeclaredBlockers.set_verdict("741", "739", :confirm)

      result = PushRouting.maybe_pause_on_request(state(), "741", dependency_pause("739"))

      assert result.running["issue-741"].paused_reason == :blocker_dependency
      assert result.running["issue-741"].blocker_pause.blocker_identifier == "739"
    end

    test "a dismissed link stays running without another alert" do
      declare("741", "739")
      assert_receive {:event, _}, 500
      assert :ok = DeclaredBlockers.set_verdict("741", "739", :dismiss)

      result = PushRouting.maybe_pause_on_request(state(), "741", dependency_pause("739"))

      assert result.running["issue-741"].control.status == :working
      refute_receive {:event, _}, 100
    end

    test "a planned link the worker never declared still pauses" do
      result = PushRouting.maybe_pause_on_request(state(), "741", dependency_pause("738"))
      assert result.running["issue-741"].paused_reason == :blocker_dependency
    end
  end

  describe "dispatch gate" do
    test "an unconfirmed declared link does not hold while a planned link still does", ctx do
      declare("741", "739")
      refute DispatchPolicy.issue_held_by_dependency?(dependent([blocker("739")]), ctx.terminal)

      planned = dependent([blocker("739"), blocker("738")])
      assert DispatchPolicy.issue_held_by_dependency?(planned, ctx.terminal)
      assert DispatchPolicy.holding_blockers(planned, ctx.terminal) == [blocker("738")]
    end

    test "a confirmed declared link holds", ctx do
      declare("741", "739")
      assert :ok = DeclaredBlockers.set_verdict("741", "739", :confirm)
      assert DispatchPolicy.issue_held_by_dependency?(dependent([blocker("739")]), ctx.terminal)
    end

    test "the Executor CLI verdict refuses an undeclared link and records a declared one" do
      refused = ExUnit.CaptureIO.capture_io(fn -> Blocker.run(action: :confirm, ticket: "741", blocker: "739") end)
      assert refused =~ "#741 has no worker-declared blocker #739"
      assert refused =~ "__AIUR_CONTROL_EXIT__:1"

      declare("741", "739")
      dismissed = ExUnit.CaptureIO.capture_io(fn -> Blocker.run(action: :dismiss, ticket: "741", blocker: "739") end)
      assert dismissed =~ "#739 stays advisory for #741"
      assert DeclaredBlockers.status("741", "739") == "dismissed"
    end

    test "only a declared link can be confirmed or dismissed" do
      assert {:error, :not_declared} = DeclaredBlockers.set_verdict("741", "738", :dismiss)
      assert DeclaredBlockers.status("741", "738") == nil
    end
  end

  describe "durable record" do
    test "survives a reload and unblock removes it", ctx do
      declare("741", "739")
      declare("741", "740")
      assert {:ok, %{"741" => %{"739" => "declared", "740" => "declared"}}} = JsonStore.read(ctx.path)

      assert {:ok, :removed} = DeclaredBlockers.after_unblock({:ok, :removed}, issue(), 739)
      assert DeclaredBlockers.advisory("741") == MapSet.new(["740"])
      assert {:ok, %{"741" => %{"740" => "declared"}}} = JsonStore.read(ctx.path)
    end

    test "a failed declaration or unblock leaves the record unchanged", ctx do
      assert {:error, :boom} = DeclaredBlockers.after_declare({:error, :boom}, issue(), 739)
      assert {:ok, %{}} = JsonStore.read(ctx.path, %{})

      declare("741", "739")
      assert {:error, :boom} = DeclaredBlockers.after_unblock({:error, :boom}, issue(), 739)
      assert DeclaredBlockers.status("741", "739") == "declared"
    end

    test "re-declaring keeps the Executor verdict" do
      declare("741", "739")
      assert :ok = DeclaredBlockers.set_verdict("741", "739", :confirm)
      declare("741", "739")
      assert DeclaredBlockers.status("741", "739") == "confirmed"
    end
  end

  defp declare(ticket, blocker) do
    assert {:ok, :pending} = DeclaredBlockers.after_declare({:ok, :pending}, issue(ticket), String.to_integer(blocker))
  end

  defp issue(ticket \\ "741"), do: %Issue{id: "issue-#{ticket}", identifier: ticket, title: "t", state: "in-progress", blocked_by: []}
  defp dependent(blockers), do: %{issue() | state: "todo", blocked_by: blockers}
  defp blocker(id), do: %{id: id, identifier: id, state: "in-progress"}
  defp dependency_pause(blocker), do: %{payload: %{reason: "dependency", blocker_identifier: blocker}}

  defp state do
    entry = %{identifier: "741", pid: self(), issue: issue(), control: %{status: :working, can_interrupt: true}}
    %State{running: %{"issue-741" => entry}, completed: MapSet.new(), claimed: MapSet.new(), retry_attempts: %{}, last_polled_issues: %{}}
  end
end
