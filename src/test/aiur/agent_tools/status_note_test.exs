defmodule Aiur.AgentTools.StatusNoteTest do
  # The status note is read by the Executor and the voice assistant, so a note
  # that is too long, multi-line, misspelled or mistyped must be rejected with
  # an error that tells the agent which limit it broke.
  use ExUnit.Case, async: true

  alias Aiur.AgentTools.StatusNote

  defp note(overrides \\ %{}) do
    Map.merge(%{"doing" => "running tests", "updated_reason" => "phase"}, overrides)
  end

  describe "validate/2" do
    test "fills missing optional fields, accepts a numeric PR, and trims" do
      assert {:ok, "m", payload} = StatusNote.validate("m", %{doing: "  coding  ", pr: 4085, updated_reason: "phase"})
      assert payload["doing"] == "coding"
      assert payload["pr"] == "4085"
      assert payload["asks"] == ""
    end

    test "rejects a note without `doing`" do
      assert {:error, {:status_note_invalid, message}} = StatusNote.validate("m", note(%{"doing" => " "}))
      assert message =~ "`doing` is required"
    end

    test "rejects an unknown field so typos do not silently drop data" do
      assert {:error, {:status_note_invalid, message}} = StatusNote.validate("m", Map.put(note(), "doign", "x"))
      assert message =~ "doign"
    end

    test "rejects a non-string field and a bad updated_reason" do
      assert {:error, {:status_note_invalid, message}} = StatusNote.validate("m", note(%{"next" => ["a", "b"]}))
      assert message =~ "`next` must be a string"

      assert {:error, {:status_note_invalid, message}} = StatusNote.validate("m", note(%{"updated_reason" => "whenever"}))
      assert message =~ "turn_end"
    end

    test "a pasted log is rejected against the whole-payload cap first" do
      assert {:error, {:status_note_invalid, message}} = StatusNote.validate("m", note(%{"next" => String.duplicate("log line\n", 200)}))
      assert message =~ "the limit is 1280 bytes"
    end

    test "a note with every field at its own cap still fits the whole-payload cap" do
      full = note(%{"doing" => String.duplicate("d", 200), "why" => String.duplicate("w", 200), "next" => String.duplicate("n", 200)})
      full = Map.merge(full, %{"asks" => String.duplicate("a", 200), "risks" => String.duplicate("r", 160), "waiting_on" => String.duplicate("o", 120)})
      # `pr` at its 16-byte cap and `long_step`, the longest updated_reason.
      full = Map.merge(full, %{"pr" => String.duplicate("9", 16), "updated_reason" => "long_step"})

      assert {:ok, "m", _payload} = StatusNote.validate("m", full)
    end

    test "caps the one-line message at 200 bytes and names the limit" do
      assert {:ok, _message, _payload} = StatusNote.validate(String.duplicate("m", 200), note())

      assert {:error, {:status_note_invalid, message}} = StatusNote.validate(String.duplicate("m", 201), note())
      assert message =~ "`message` is 201 bytes; the limit is 200 bytes"
    end

    test "rejects a multi-line message so logs cannot ride in the summary" do
      assert {:error, {:status_note_invalid, message}} = StatusNote.validate("line one\nline two", note())
      assert message =~ "`message` must be one line"
    end
  end
end
