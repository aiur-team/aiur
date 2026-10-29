defmodule Aiur.DecisionEventLegacyHashTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionEvent, DecisionProjection, DecisionValidation, Journal}

  @ticket %{identifier: "6246", title: "Replay", url: "https://github.com/aiur-team/aiur/issues/6246"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}

  # A `requested` record exactly as the writer before #5506 put it on disk: its
  # Decision snapshot had no `pending_for_session` / `ticket_comment_status` keys,
  # and its schema-1 hash covered that snapshot without provenance (#6246).
  defp pre_5506_requested_line, do: requested_line(fn data -> Map.drop(data, ["pending_for_session", "ticket_comment_status"]) end)

  # Written while #5506 was live: the snapshot and its hash carry the default keys.
  defp during_5506_requested_line do
    requested_line(fn data -> Map.merge(data, %{"pending_for_session" => false, "ticket_comment_status" => nil}) end)
  end

  defp requested_line(encode_snapshot) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, decision} =
      DecisionValidation.normalize(%{"question" => "Ship it?", "blocking" => true}, ticket: @ticket, source: @source, now: now)

    {:ok, event} =
      DecisionEvent.new(:requested, decision.decision_id, decision.version, decision, event_id: 1, run_id: "run-1", now: now)

    raw = event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()
    data = encode_snapshot.(raw["data"])
    hashed_data = Map.drop(data, ["provenance", "provenance_hash", "provenance_state"])

    old_hash =
      DecisionValidation.content_hash(%{
        schema_version: 1,
        event_type: :requested,
        event_id: raw["event_id"],
        run_id: raw["run_id"],
        decision_id: raw["decision_id"],
        decision_version: raw["decision_version"],
        occurred_at: raw["occurred_at"],
        data: hashed_data
      })

    raw |> Map.put("data", data) |> Map.put("content_hash", old_hash) |> Jason.encode!()
  end

  @tag :tmp_dir
  test "a journal with a requested record written before the session-delivery fields replays", %{tmp_dir: tmp_dir} do
    assert_replays(tmp_dir, pre_5506_requested_line())
  end

  # Regression guard: the #6246 fix must not strand records the #5506 writer produced.
  @tag :tmp_dir
  test "a requested record written while the session-delivery keys were hashed still replays", %{tmp_dir: tmp_dir} do
    assert_replays(tmp_dir, during_5506_requested_line())
  end

  test "a requested record whose stored hash matches neither material still fails" do
    for line <- [pre_5506_requested_line(), during_5506_requested_line()] do
      tampered = line |> Jason.decode!() |> Map.update!("content_hash", &String.reverse/1)
      assert {:error, :event_content_hash_mismatch} = DecisionEvent.from_json_safe(tampered)
    end
  end

  defp assert_replays(tmp_dir, line) do
    path = Path.join(tmp_dir, "decisions.ndjson")
    File.write!(path, line <> "\n")

    # The daemon boot path (DecisionStore.Boot): replay, then fold.
    assert {:ok, [%DecisionEvent{type: :requested}] = records, nil} =
             Journal.replay(path, &DecisionProjection.decode_record/1)

    assert {%{current: current}, nil} = DecisionProjection.reduce_checked(records)
    decision_id = Jason.decode!(line)["decision_id"]
    assert %{^decision_id => %{decision_status: :open, pending_for_session?: false, ticket_comment_status: nil}} = current
    # The journal is read, never rewritten.
    assert File.read!(path) == line <> "\n"
  end
end
