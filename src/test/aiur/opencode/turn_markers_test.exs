defmodule Aiur.Opencode.TurnMarkersTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.TurnMarkers

  describe "parse_turn_id/1" do
    test "splits a continuation id into parent and segment" do
      assert TurnMarkers.parse_turn_id("t1abc-s3") == {"t1abc", 3}
      assert TurnMarkers.parse_turn_id("t9xyz-s12") == {"t9xyz", 12}
    end

    test "a bare parent id is segment 0" do
      assert TurnMarkers.parse_turn_id("t1abc") == {"t1abc", 0}
    end

    test "round-trips continuation_id/2" do
      id = TurnMarkers.continuation_id("t1abc", 4)
      assert TurnMarkers.parse_turn_id(id) == {"t1abc", 4}
    end
  end

  describe "post_continuation/5" do
    test "posts the suffixed marker to ONLY the given writer" do
      tp = self()
      writer = %{session_id: "ses_1", base_url: "http://one"}

      post_fn = fn base_url, session_id, payload ->
        send(tp, {:posted, base_url, session_id, payload})
        {:ok, %{}}
      end

      :ok = TurnMarkers.post_continuation("99", "t1abc", 2, writer, post_fn)

      assert_receive {:posted, "http://one", "ses_1", payload}, 1_000
      assert [part] = payload.parts
      assert part["text"] == "__aiur_turn__:t1abc-s2"
      assert part["synthetic"] == true
      refute_receive {:posted, _, _, _}, 100
    end

    test "retries once on a connection error" do
      tp = self()
      writer = %{session_id: "ses_1", base_url: "http://one"}

      {:ok, agent} = Agent.start_link(fn -> 0 end)

      post_fn = fn _base_url, _session_id, _payload ->
        attempt = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
        send(tp, {:attempt, attempt})
        if attempt == 1, do: {:error, {:transport, :econnrefused}}, else: {:ok, %{}}
      end

      :ok = TurnMarkers.post_continuation("99", "t1abc", 1, writer, post_fn)

      assert_receive {:attempt, 1}, 1_000
      assert_receive {:attempt, 2}, 1_000
      refute_receive {:attempt, 3}, 100
    end

    test "NEVER retries on timeout — opencode already queued the marker" do
      # opencode holds the POST open until the marker's own completion ends
      # (a whole segment), so the HTTP timeout fires on EVERY continuation.
      # A retry here duplicated the marker and N×-rendered the whole turn.
      tp = self()
      writer = %{session_id: "ses_1", base_url: "http://one"}

      post_fn = fn _base_url, _session_id, _payload ->
        send(tp, :attempt)
        {:error, {:transport, :timeout}}
      end

      :ok = TurnMarkers.post_continuation("99", "t1abc", 1, writer, post_fn)

      assert_receive :attempt, 1_000
      refute_receive :attempt, 200
    end
  end

  describe "post_all/4" do
    test "fans the bare marker out to every writer" do
      tp = self()

      writers = [
        %{session_id: "ses_1", base_url: "http://one"},
        %{session_id: "ses_2", base_url: "http://two"}
      ]

      post_fn = fn base_url, session_id, payload ->
        send(tp, {:posted, base_url, session_id, payload})
        {:ok, %{}}
      end

      :ok = TurnMarkers.post_all("99", "t1abc", writers, post_fn)

      assert_receive {:posted, "http://one", "ses_1", %{parts: [part1]}}, 1_000
      assert_receive {:posted, "http://two", "ses_2", %{parts: [part2]}}, 1_000
      assert part1["text"] == "__aiur_turn__:t1abc"
      assert part2["text"] == "__aiur_turn__:t1abc"
    end
  end
end
