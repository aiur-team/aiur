Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.JournalUpgradeRepairTest do
  use Aiur.DecisionStoreCase, async: false

  import ExUnit.CaptureIO

  alias Aiur.CommandsCLI.Repair
  alias Aiur.DecisionValidation

  @options [%{"id" => "yes", "label" => "Yes"}, %{"id" => "no", "label" => "No"}]

  # Two open Commands; the first is answered, so the journal holds an
  # `answer_recorded` record whose wire shape differs between builds (#7528).
  defp journal_with_answer(dir) do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)
    {:ok, %{decision: answered}} = request(pid, %{"question" => "Answered before the upgrade?", "blocking" => true, "options" => @options})
    {:ok, %{decision: open}} = request(pid, %{"question" => "Still open after the upgrade?", "blocking" => true, "options" => @options})

    {:ok, %{status: :accepted}} =
      answer(pid, answered.decision_id, %{"idempotency_key" => "before-upgrade", "expected_version" => answered.version, "option_id" => "yes"})

    GenServer.stop(pid)
    {answered, open}
  end

  # Rewrites one record as another build would have written it: new data, and
  # the content hash that build computed over exactly that data.
  defp rewrite_record(dir, type, fun) do
    path = Path.join(dir, "decisions.ndjson")

    lines =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Jason.decode!(line) do
          %{"event_type" => ^type} = raw -> raw |> rehash(fun.(raw["data"])) |> Jason.encode!()
          _other -> line
        end
      end)

    File.write!(path, Enum.map(lines, &[&1, "\n"]))
    path
  end

  defp rehash(raw, data) do
    material = %{
      schema_version: raw["schema_version"],
      event_type: String.to_existing_atom(raw["event_type"]),
      event_id: raw["event_id"],
      run_id: raw["run_id"],
      decision_id: raw["decision_id"],
      decision_version: raw["decision_version"],
      occurred_at: raw["occurred_at"],
      data: data
    }

    %{raw | "data" => data, "content_hash" => DecisionValidation.content_hash(material)}
  end

  defp tamper_hash(line), do: line |> Jason.decode!() |> Map.update!("content_hash", &String.reverse/1) |> Jason.encode!()

  defp assert_upgraded_store_answers(dir, answered, open) do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)
    assert DecisionStore.health(pid) == :writable
    assert {:ok, %{decision_status: :decided, answer: %{selected_option_id: "yes"}}} = DecisionStore.get(answered.decision_id, pid)

    assert {:ok, %{status: :accepted}} =
             answer(pid, open.decision_id, %{"idempotency_key" => "after-upgrade", "expected_version" => open.version, "option_id" => "no"})

    assert {:ok, %{decision_status: :decided, answer: %{selected_option_id: "no"}}} = DecisionStore.get(open.decision_id, pid)
  end

  describe "upgrades across the answer media wire change (#7528)" do
    test "an answer written before answers carried media replays writable and the store still answers", %{dir: dir} do
      {answered, open} = journal_with_answer(dir)
      rewrite_record(dir, "answer_recorded", &Map.delete(&1, "media"))

      assert_upgraded_store_answers(dir, answered, open)
    end

    test "an answer written with an empty media list replays writable after the list is no longer written", %{dir: dir} do
      {answered, open} = journal_with_answer(dir)
      path = rewrite_record(dir, "answer_recorded", &Map.put(&1, "media", []))
      assert File.read!(path) =~ ~s("media":[])

      assert_upgraded_store_answers(dir, answered, open)
    end

    test "a record whose stored hash matches neither the encoder nor the stored data still latches read-only", %{dir: dir} do
      {_answered, open} = journal_with_answer(dir)
      path = rewrite_record(dir, "answer_recorded", &Map.put(&1, "media", []))
      [requested_a, requested_b, answer_line | rest] = path |> File.read!() |> String.split("\n", trim: true)
      File.write!(path, Enum.map([requested_a, requested_b, tamper_hash(answer_line) | rest], &[&1, "\n"]))

      pid = start_store!(dir, dispatch_delay_ms: 60_000)
      assert {:corrupt, 3, :event_content_hash_mismatch} = DecisionStore.health(pid)

      assert {:error, {:store_unavailable, {:corrupt, 3, :event_content_hash_mismatch}}} =
               answer(pid, open.decision_id, %{"idempotency_key" => "blocked", "expected_version" => open.version, "option_id" => "no"})
    end
  end

  describe "repair_journal/1" do
    test "quarantines a genuinely corrupt record, keeps every valid one, and restores writes", %{dir: dir} do
      {answered, open} = journal_with_answer(dir)
      path = Path.join(dir, "decisions.ndjson")
      [requested_a, requested_b, answer_line | rest] = path |> File.read!() |> String.split("\n", trim: true)
      tampered = tamper_hash(answer_line)
      refute tampered == answer_line

      pid = start_store!(dir, dispatch_delay_ms: 60_000)
      {:ok, %{decision: later}} = request(pid, %{"question" => "Written after the damaged record?", "blocking" => false})
      GenServer.stop(pid)

      later_lines = path |> File.read!() |> String.split("\n", trim: true) |> Enum.drop(3 + length(rest))
      File.write!(path, Enum.map([requested_a, requested_b, tampered | rest ++ later_lines], &[&1, "\n"]))

      pid = start_store!(dir, dispatch_delay_ms: 60_000)
      assert {:corrupt, 3, :event_content_hash_mismatch} = DecisionStore.health(pid)
      # Replay stops at the damaged record, so the later Command is invisible.
      assert {:error, :not_found} = DecisionStore.get(later.decision_id, pid)

      assert {:ok, report} = DecisionStore.repair_journal(pid)
      assert report.health == :writable
      assert [%{line: 3, reason: :event_content_hash_mismatch}] = report.quarantined
      assert report.kept == 2 + length(rest) + length(later_lines)
      assert File.read!(report.quarantine_path) == tampered <> "\n"
      assert File.read!(path) == Enum.map_join([requested_a, requested_b | rest ++ later_lines], &(&1 <> "\n"))

      assert DecisionStore.health(pid) == :writable
      assert {:ok, %{decision_status: :open}} = DecisionStore.get(later.decision_id, pid)
      assert {:ok, %{decision_status: :open, answer: nil}} = DecisionStore.get(answered.decision_id, pid)

      # A Command whose ticket closed can be retired once writes are back.
      assert {:ok, _result} =
               DecisionStore.moot(open.decision_id, %{"reason_class" => "ticket_closed", "expected_version" => open.version}, [actor: %{kind: :operator, id: "operator-1"}], pid)

      assert {:ok, %{decision_status: :moot}} = DecisionStore.get(open.decision_id, pid)

      GenServer.stop(pid)
      pid = start_store!(dir, dispatch_delay_ms: 60_000)
      assert DecisionStore.health(pid) == :writable
      assert {:ok, %{decision_status: :moot}} = DecisionStore.get(open.decision_id, pid)
    end

    test "a verified journal is left untouched", %{dir: dir} do
      journal_with_answer(dir)
      path = Path.join(dir, "decisions.ndjson")
      before = File.read!(path)

      pid = start_store!(dir, dispatch_delay_ms: 60_000)
      assert {:ok, %{quarantined: [], quarantine_path: nil, kept: kept, health: :writable}} = DecisionStore.repair_journal(pid)
      assert kept == before |> String.split("\n", trim: true) |> length()
      assert File.read!(path) == before
    end
  end

  describe "aiur commands repair" do
    test "exits non-zero when the store is still not writable after repair" do
      report = %{kept: 1, quarantined: [%{line: 2, reason: :invalid_json}], quarantine_path: "/q.ndjson", health: {:corrupt, 4, :boom}}

      output = capture_io(fn -> assert Repair.run(repair_fun: fn -> {:ok, report} end) == 1 end)
      assert output =~ "line 2: :invalid_json"

      json = capture_io(fn -> assert Repair.run(repair_fun: fn -> {:ok, %{report | health: :writable}} end, json: true) == 0 end)
      assert %{"kept" => 1, "quarantine_path" => "/q.ndjson", "health" => ":writable"} = Jason.decode!(json)
    end
  end
end
