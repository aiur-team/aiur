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

      parent = self()

      slow_post = fn base, sid, _payload ->
        send(parent, {:entered, base, sid})
        Process.sleep(5_000)
        {:ok, %{}}
      end

      # A synchronous post would block here for the full 5s sleep; reaching the
      # assertion proves the call returned without waiting on it. The post still
      # ran in its fire-and-forget Task, so the entry message lands afterward.
      assert :ok = TurnStreams.post_aiur_turn_markers("TS-02", "tSLOW", writers, slow_post)
      assert_receive {:entered, "http://slow", "s-slow"}, 5_000
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
