defmodule Aiur.AgentRunner.TurnStreamsTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentPubSub, Issue}
  alias Aiur.AgentRunner.TurnStreams
  alias Aiur.Opencode.ActiveTurns

  describe "open/1" do
    test "returns a binary aiur_turn_id for a valid Issue" do
      issue = %Issue{identifier: "TS-open-#{System.unique_integer([:positive])}"}

      result = TurnStreams.open(issue)

      assert is_binary(result)
    end

    test "registers the entry in ActiveTurns before returning" do
      identifier = "TS-reg-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      aiur_turn_id = TurnStreams.open(issue)

      assert ActiveTurns.lookup(identifier, aiur_turn_id) == :active
    end

    test "returns nil for a non-Issue" do
      assert TurnStreams.open(nil) == nil
      assert TurnStreams.open(%{}) == nil
      assert TurnStreams.open("not_an_issue") == nil
    end

    test "returns nil for an Issue with a non-binary identifier" do
      issue = %Issue{identifier: nil}
      assert TurnStreams.open(issue) == nil
    end
  end

  describe "close/3" do
    test "marks the turn closed in ActiveTurns" do
      identifier = "TS-close-#{System.unique_integer([:positive])}"
      turn_id = "tCLOSE#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      ActiveTurns.put(identifier, turn_id)
      TurnStreams.close(issue, turn_id, :done)

      assert ActiveTurns.lookup(identifier, turn_id) == {:closed, :done}
    end

    test "broadcasts aiur_turn_done to AgentPubSub subscribers" do
      identifier = "TS-bcast-#{System.unique_integer([:positive])}"
      turn_id = "tBCAST#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      :ok = AgentPubSub.subscribe_agent(identifier)
      ActiveTurns.put(identifier, turn_id)
      TurnStreams.close(issue, turn_id, :done)

      assert_receive {:aiur_turn_done, ^identifier, ^turn_id, :done}, 2_000
    end

    test "preserves the close reason verbatim" do
      identifier = "TS-reason-#{System.unique_integer([:positive])}"
      turn_id = "tREASON#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      ActiveTurns.put(identifier, turn_id)
      TurnStreams.close(issue, turn_id, {:failed, :timeout})

      assert ActiveTurns.lookup(identifier, turn_id) == {:closed, {:failed, :timeout}}
    end

    test "no-ops for a nil aiur_turn_id" do
      issue = %Issue{identifier: "TS-nil-turn"}
      assert :ok = TurnStreams.close(issue, nil, :done)
    end

    test "no-ops for a non-Issue" do
      assert :ok = TurnStreams.close(%{}, "t123", :done)
    end
  end

  describe "workspace exclusion" do
    test "turn registration waits for the same identifier's workspace operation" do
      identifier = "TS-lock-#{System.unique_integer([:positive])}"
      parent = self()

      workspace_task =
        Task.async(fn ->
          ActiveTurns.with_inactive_turn(identifier, fn ->
            send(parent, :workspace_locked)
            assert_receive :release_workspace, 2_000
            :ok
          end)
        end)

      assert_receive :workspace_locked

      turn_task =
        Task.async(fn ->
          result = ActiveTurns.put(identifier, "tWAIT")
          send(parent, :turn_registered)
          result
        end)

      refute_receive :turn_registered, 100

      send(workspace_task.pid, :release_workspace)
      assert Task.await(workspace_task) == {:ok, :ok}
      assert_receive :turn_registered, 1_000
      assert Task.await(turn_task) == :ok
      assert ActiveTurns.lookup(identifier, "tWAIT") == :active
    end

    test "workspace operations remain independent across identifiers" do
      locked_identifier = "TS-lock-a-#{System.unique_integer([:positive])}"
      other_identifier = "TS-lock-b-#{System.unique_integer([:positive])}"
      parent = self()

      workspace_task =
        Task.async(fn ->
          ActiveTurns.with_inactive_turn(locked_identifier, fn ->
            send(parent, :workspace_locked)
            assert_receive :release_workspace, 2_000
            :ok
          end)
        end)

      assert_receive :workspace_locked
      assert :ok = ActiveTurns.put(other_identifier, "tOTHER")
      assert ActiveTurns.lookup(other_identifier, "tOTHER") == :active

      send(workspace_task.pid, :release_workspace)
      assert Task.await(workspace_task) == {:ok, :ok}
    end

    test "subscriber registration cannot create an active entry during workspace bootstrap" do
      identifier = "TS-subscriber-lock-#{System.unique_integer([:positive])}"
      parent = self()

      workspace_task =
        Task.async(fn ->
          ActiveTurns.with_inactive_turn(identifier, fn ->
            send(parent, :workspace_locked)
            assert_receive :release_workspace, 2_000
            :ok
          end)
        end)

      assert_receive :workspace_locked

      subscriber_task =
        Task.async(fn ->
          result = ActiveTurns.register_subscriber(identifier, "tSUBSCRIBER", self())
          send(parent, :subscriber_registered)
          result
        end)

      refute_receive :subscriber_registered, 100

      send(workspace_task.pid, :release_workspace)
      assert Task.await(workspace_task) == {:ok, :ok}
      assert_receive :subscriber_registered, 1_000
      assert Task.await(subscriber_task) == {:ok, nil}
      assert ActiveTurns.lookup(identifier, "tSUBSCRIBER") == :active
    end
  end

  describe "post_aiur_turn_markers/4" do
    test "fires exactly one post per attached writer" do
      parent = self()

      writers = [
        %{session_id: "s1", base_url: "http://host1"},
        %{session_id: "s2", base_url: "http://host2"}
      ]

      post_fn = fn base, sid, _payload ->
        send(parent, {:posted, base, sid})
        {:ok, %{}}
      end

      :ok = TurnStreams.post_aiur_turn_markers("TS-01", "tPOST", writers, post_fn)

      assert_receive {:posted, "http://host1", "s1"}, 2_000
      assert_receive {:posted, "http://host2", "s2"}, 2_000
    end

    test "returns :ok immediately (fire-and-forget)" do
      writers = [%{session_id: "s-slow", base_url: "http://slow"}]

      slow_post = fn _base, _sid, _payload ->
        Process.sleep(5_000)
        {:ok, %{}}
      end

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          TurnStreams.post_aiur_turn_markers("TS-02", "tSLOW", writers, slow_post)
        end)

      assert div(elapsed_us, 1_000) < 500,
             "post_aiur_turn_markers should return immediately"
    end

    test "returns :ok when the post_fn returns an error" do
      writers = [%{session_id: "s-err", base_url: "http://err"}]
      failing_post = fn _base, _sid, _payload -> {:error, :nxdomain} end

      assert :ok = TurnStreams.post_aiur_turn_markers("TS-03", "tERR", writers, failing_post)
    end

    test "returns :ok for an empty writer list" do
      assert :ok = TurnStreams.post_aiur_turn_markers("TS-04", "tEMPTY", [], fn _, _, _ -> :ok end)
    end
  end
end
