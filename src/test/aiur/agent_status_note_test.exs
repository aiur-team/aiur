defmodule Aiur.AgentStatusNoteTest do
  # The status note is what the Executor and the voice assistant read to
  # answer "what is the agent doing and why" without interrupting it. These
  # tests pin the protocol: a valid note is published AND kept as the latest
  # note; a bad note never reaches the bus; secrets never reach either; and a
  # chatty agent cannot flood the bus past the per-turn cap.
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AgentStatusNote
  alias Aiur.AgentTools.EmitEvent
  alias Aiur.Events.Exchange
  alias Aiur.Issue

  @token "ghp_" <> String.duplicate("a", 36)

  setup do
    EmitEvent.reset_turn_quotas()
    root = Path.join(System.tmp_dir!(), "aiur-status-note-#{System.unique_integer([:positive])}")
    previous_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(root, "aiur.log"))

    on_exit(fn ->
      restore_env(:log_file, previous_log_file)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)

  defp note(overrides \\ %{}) do
    Map.merge(
      %{
        "doing" => "running the focused emit_event tests",
        "why" => "plan step 2: validator",
        "next" => "wire the store, then the prompt text",
        "waiting_on" => "",
        "asks" => "",
        "risks" => "errors.ex is near the size cap",
        "pr" => "",
        "updated_reason" => "long_step"
      },
      overrides
    )
  end

  defp emit(executor, payload, message \\ "validator tests running") do
    response = executor.("emit_event", %{"name" => "progress.status", "message" => message, "payload" => payload})
    {response["success"], Jason.decode!(response["output"])}
  end

  defp executor_for(identifier), do: ToolExecutor.build(%Issue{identifier: identifier}, nil, nil)

  defp unique_identifier, do: "SN-#{System.unique_integer([:positive])}"

  describe "through the emit_event tool" do
    test "a valid note is published on ticket.<id>.agent.progress.status and stored as latest" do
      identifier = unique_identifier()
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress.status")

      assert {true, _output} = emit(executor_for(identifier), note())

      assert_receive {:event, event}, 2_000
      assert event.topic == "ticket.#{identifier}.agent.progress.status"
      assert event["doing"] == "running the focused emit_event tests"
      refute_receive {:event, _second}, 100

      assert {:ok, stored} = AgentStatusNote.latest(identifier)
      assert stored["version"] == 1
      assert stored["doing"] == "running the focused emit_event tests"
      assert stored["message"] == "validator tests running"
      assert {:ok, _at, _offset} = DateTime.from_iso8601(stored["observed_at"])
    end

    test "each later note replaces the latest one and bumps the version" do
      identifier = unique_identifier()
      executor = executor_for(identifier)

      assert {true, _} = emit(executor, note())
      assert {true, _} = emit(executor, note(%{"doing" => "waiting for CI", "waiting_on" => "CI", "updated_reason" => "turn_end"}))

      assert {:ok, %{"version" => 2, "doing" => "waiting for CI", "waiting_on" => "CI"}} = AgentStatusNote.latest(identifier)
    end

    test "an oversized note is rejected with the limit in the error and nothing is published or stored" do
      identifier = unique_identifier()
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress.status")

      assert {false, %{"error" => %{"message" => message}}} =
               emit(executor_for(identifier), note(%{"doing" => String.duplicate("x", 201)}))

      assert message =~ "`doing`"
      assert message =~ "200 bytes"
      refute_receive {:event, _event}, 200
      assert AgentStatusNote.latest(identifier) == :none
    end

    test "a token in a note is redacted before publish and store" do
      identifier = unique_identifier()
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress.status")

      assert {true, _} = emit(executor_for(identifier), note(%{"risks" => "leaked #{@token}"}), "message #{@token}")

      assert_receive {:event, event}, 2_000
      published = Jason.encode!(Map.drop(event, [:ticket_observation]))
      assert published =~ "[REDACTED:"
      refute published =~ @token

      {:ok, stored} = AgentStatusNote.latest(identifier)
      assert stored["risks"] =~ "[REDACTED:"
      assert stored["message"] =~ "[REDACTED:"
      refute Jason.encode!(stored) =~ @token
    end

    test "the 7th note in one turn is rejected, and a new turn restores the budget" do
      identifier = unique_identifier()
      executor = executor_for(identifier)

      for _ <- 1..6, do: assert({true, _} = emit(executor, note()))

      assert {false, %{"error" => %{"message" => message}}} = emit(executor, note())
      assert message =~ "6 per turn"
      assert {:ok, %{"version" => 6}} = AgentStatusNote.latest(identifier)

      EmitEvent.reset_turn_quotas()
      assert {true, _} = emit(executor, note())
    end

    test "status notes do not spend the bare progress budget" do
      executor = executor_for(unique_identifier())

      for _ <- 1..3, do: assert({true, _} = emit(executor, note()))

      for percent <- [30, 40] do
        response = executor.("emit_event", %{"name" => "progress", "message" => "bar", "payload" => %{"percent" => percent}})
        assert response["success"]
      end
    end
  end

  describe "validate/2" do
    test "fills missing optional fields, accepts a numeric PR, and trims" do
      assert {:ok, "m", payload} = AgentStatusNote.validate("m", %{doing: "  coding  ", pr: 4085, updated_reason: "phase"})
      assert payload["doing"] == "coding"
      assert payload["pr"] == "4085"
      assert payload["asks"] == ""
    end

    test "rejects a note without `doing`" do
      assert {:error, {:status_note_invalid, message}} = AgentStatusNote.validate("m", note(%{"doing" => " "}))
      assert message =~ "`doing` is required"
    end

    test "rejects an unknown field so typos do not silently drop data" do
      assert {:error, {:status_note_invalid, message}} = AgentStatusNote.validate("m", Map.put(note(), "doign", "x"))
      assert message =~ "doign"
    end

    test "rejects a non-string field and a bad updated_reason" do
      assert {:error, {:status_note_invalid, message}} = AgentStatusNote.validate("m", note(%{"next" => ["a", "b"]}))
      assert message =~ "`next` must be a string"

      assert {:error, {:status_note_invalid, message}} = AgentStatusNote.validate("m", note(%{"updated_reason" => "whenever"}))
      assert message =~ "turn_end"
    end

    test "a pasted log is rejected against the whole-payload cap first" do
      assert {:error, {:status_note_invalid, message}} = AgentStatusNote.validate("m", note(%{"next" => String.duplicate("log line\n", 200)}))
      assert message =~ "the limit is 1200 bytes"
    end

    test "a note with every field at its own cap still fits the whole-payload cap" do
      full = note(%{"doing" => String.duplicate("d", 200), "why" => String.duplicate("w", 200), "next" => String.duplicate("n", 200)})
      full = Map.merge(full, %{"asks" => String.duplicate("a", 200), "risks" => String.duplicate("r", 160), "waiting_on" => String.duplicate("o", 120)})

      assert {:ok, "m", _payload} = AgentStatusNote.validate("m", full)
    end
  end

  describe "latest/2" do
    test "is :none for a ticket with no note or a corrupt file", %{root: root} do
      assert AgentStatusNote.latest("no-note", root: root) == :none

      {:ok, _} = AgentStatusNote.record("corrupt", "m", note(), root: root)
      [path] = Path.wildcard(Path.join(root, "*.corrupt.json"))
      File.write!(path, "{not json")

      assert AgentStatusNote.latest("corrupt", root: root) == :none
    end

    test "keeps notes per ticket", %{root: root} do
      {:ok, _} = AgentStatusNote.record("1", "m", note(%{"doing" => "one"}), root: root)
      {:ok, _} = AgentStatusNote.record("2", "m", note(%{"doing" => "two"}), root: root)

      assert {:ok, %{"doing" => "one", "version" => 1}} = AgentStatusNote.latest("1", root: root)
      assert {:ok, %{"doing" => "two", "version" => 1}} = AgentStatusNote.latest("2", root: root)
    end
  end
end
