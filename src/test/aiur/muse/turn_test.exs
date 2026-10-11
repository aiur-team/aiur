defmodule Aiur.Muse.TurnTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Muse.Approvals
  import Aiur.TestSupport.MuseFixture, only: [run_fixture: 2, run_fixture: 3, frames: 1]

  @tag :tmp_dir
  test "receipt alone does not finish; native terminal and view items reach the runner", %{tmp_dir: dir} do
    task = run_fixture(dir, "complete")
    receive_barrier({:event, %{event: :notification, muse_item_kind: "agentMessage"}})
    assert {:ok, %{result: :turn_completed, thread_id: "native-session", turn_id: "turn-1", view_cursor: "view-2"}} = Task.await(task, :infinity)
    assert Enum.map(frames(dir), & &1["method"]) == ["initialize", "initialized", "session/start", "usage/read", "turn/start"]
  end

  @tag :tmp_dir
  test "pause needs interrupt acceptance and matching cancelled terminal", %{tmp_dir: dir} do
    task = run_fixture(dir, "pause")
    receive_barrier({:turn_ready, owner})
    send(owner, {:pause_agent, 77, 4})
    assert {:paused, %{control: %{request_id: 77, generation: 4}, turn_id: "turn-1"}} = Task.await(task, :infinity)
    assert List.last(frames(dir))["method"] == "turn/interrupt"
  end

  @tag :tmp_dir
  test "an accepted pause racing normal completion still acknowledges the stopped turn", %{tmp_dir: dir} do
    task = run_fixture(dir, "pause_completed")
    receive_barrier({:turn_ready, owner})
    send(owner, {:pause_agent, 78, 5})

    assert {:paused, %{control: %{request_id: 78, generation: 5}, details: %{"terminal" => "completed"}, native_terminal: :completed}} =
             Task.await(task, :infinity)
  end

  @tag :tmp_dir
  test "urgent own queue wake interrupts and returns for outer queue drain", %{tmp_dir: dir} do
    task = run_fixture(dir, "pause")
    receive_barrier({:turn_ready, owner})
    send(owner, {:agent_queue_updated, "OTHER-1", 1, true})
    send(owner, {:agent_queue_updated, "MUSE-1", 2, true})
    assert {:ok, %{result: :turn_interrupted_for_operator_message}} = Task.await(task, :infinity)
    assert Enum.count(frames(dir), &(&1["method"] == "turn/interrupt")) == 1
  end

  @tag :tmp_dir
  test "native approval waits for an explicit Executor choice and confirmed resolution", %{tmp_dir: dir} do
    task = run_fixture(dir, "approval")
    receive_barrier({:event, %{payload: %{"method" => "approval/request"}}})
    refute Enum.any?(frames(dir), &(&1["method"] == "approval/decide"))
    requirement = %{"approvalId" => "approval-1", "sourceIndex" => 0}
    token = Approvals.requirement_token(requirement)
    send(task.pid, {:executor_response, "/approve approval-1 #{token} allow_once"})
    send(task.pid, {:agent_queue_updated, "MUSE-1", 8, false})
    receive_barrier({:approval_delivered, %{approval_id: "approval-1", decision: "approved"}})
    assert {:ok, %{result: :turn_completed}} = Task.await(task, :infinity)
    [decision] = Enum.filter(frames(dir), &(&1["method"] == "approval/decide"))
    assert decision["params"]["requirementId"] == requirement
    refute Enum.any?(frames(dir), &(&1["method"] == "turn/interrupt"))
  end

  @tag :tmp_dir
  test "a replayed approval request cannot reopen a resolved approval", %{tmp_dir: dir} do
    task = run_fixture(dir, "approval_replay", 2_000)
    receive_barrier({:event, %{payload: %{"method" => "item/started", "params" => %{"viewCursor" => "ready"}}}})
    send(task.pid, {:agent_queue_updated, "MUSE-1", 9, true})
    assert {:ok, %{result: :turn_interrupted_for_operator_message}} = Task.await(task, 5_000)
    assert Enum.count(frames(dir), &(&1["method"] == "turn/interrupt")) == 1
  end

  @tag :tmp_dir
  test "a write into a provider that closed stdin ends the turn at once, not at the turn timeout", %{tmp_dir: dir} do
    task = run_fixture(dir, "closed_stdin", 10_000)
    receive_barrier({:event, %{payload: %{"method" => "item/started", "params" => %{"viewCursor" => "stdin-closed"}}}})
    send(task.pid, {:pause_agent, 79, 6})
    assert {:error, {:native_port_exit, :epipe}} = Task.await(task, 5_000)
  end

  @tag :tmp_dir
  test "MCP calls execute in the runner owner while the native turn waits", %{tmp_dir: dir} do
    task = run_fixture(dir, "mcp")
    receive_barrier({:tool, owner, "aiur_test", %{"value" => 42}})
    assert owner == task.pid
    assert {:ok, %{result: :turn_completed}} = Task.await(task, :infinity)
  end

  @tag :tmp_dir
  test "an accepted receipt without a terminal times out", %{tmp_dir: dir} do
    assert {:error, :native_turn_timeout} = Task.await(run_fixture(dir, "receipt_only", 150), :infinity)
  end

  @tag :tmp_dir
  test "a malformed matching terminal fails with a typed error", %{tmp_dir: dir} do
    assert {:error, :invalid_turn_completion} = Task.await(run_fixture(dir, "bad_terminal"), :infinity)
  end
end
