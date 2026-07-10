defmodule Aiur.Opencode.OperatorTextTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.OperatorText

  describe "normalize/1 (strip opencode <system-reminder> wrappers)" do
    test "mid-stream interjection form: extracts the raw operator message" do
      wrapped =
        "<system-reminder>\nThe user sent the following message:\n" <>
          "hi from opencode, pause and respond exactly \"123\"\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>"

      assert OperatorText.normalize(wrapped) ==
               "hi from opencode, pause and respond exactly \"123\""
    end

    test "idle form: strips the 'Message sent at' reminder, keeps the raw text" do
      wrapped = "<system-reminder>Message sent at Sun 2026-06-14 17:19:23 UTC.</system-reminder>\nhi from ce, respond exactly \"456\""

      assert OperatorText.normalize(wrapped) == "hi from ce, respond exactly \"456\""
    end

    test "already-raw operator text passes through unchanged" do
      assert OperatorText.normalize("just say banana") == "just say banana"
    end

    test "a reminder with no operator content normalizes to empty (dropped upstream)" do
      assert OperatorText.normalize("<system-reminder>cwd changed to /tmp</system-reminder>") == ""
    end

    test "recovers the operator message when scaffolding reminders precede the wrapper" do
      # opencode prepends its own <system-reminder> scaffolding (cwd/goal/
      # files) to the payload, so the operator wrapper is no longer the whole
      # string. The old \A..\z-anchored match missed and the generic strip
      # deleted the operator-bearing block too -> "" -> silent drop ("never
      # answered"). Extraction must survive the surrounding scaffolding.
      payload =
        "<system-reminder>cwd changed to /tmp/work</system-reminder>\n" <>
          "<system-reminder>\nThe user sent the following message:\n" <>
          "pause and respond with exactly one word: BANANA\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>"

      assert OperatorText.normalize(payload) ==
               "pause and respond with exactly one word: BANANA"
    end

    test "recovers the operator message when a scaffolding reminder trails the wrapper" do
      payload =
        "<system-reminder>\nThe user sent the following message:\n" <>
          "respond exactly \"123\"\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>\n" <>
          "<system-reminder>goal: ship the PR</system-reminder>"

      assert OperatorText.normalize(payload) == "respond exactly \"123\""
    end

    test "recovers every operator message when opencode folds several into one batch" do
      payload =
        "<system-reminder>\nThe user sent the following message:\nfirst\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>" <>
          "<system-reminder>\nThe user sent the following message:\nsecond\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>"

      assert OperatorText.normalize(payload) == "first\nsecond"
    end

    test "never drops a present operator message to empty (silent-drop guard)" do
      # The core defect: an operator message that normalizes to "" is acked as
      # a noop (send_operator/3) and never reaches the agent. This is the
      # "never answered" + "QUEUED clears before read" double symptom.
      payload =
        "<system-reminder>selection: lib/foo.ex:1-3</system-reminder>\n" <>
          "<system-reminder>\nThe user sent the following message:\n" <>
          "say hello\n\nPlease address this message and continue with your tasks.\n</system-reminder>"

      refute OperatorText.normalize(payload) == ""
      assert OperatorText.normalize(payload) == "say hello"
    end

    test "CRLF line endings still recover the operator message" do
      # Defensive: if a wrapper ever reaches normalize with CRLF endings, the
      # `\r?\n` tolerance keeps it matching instead of falling through to the
      # over-deleting generic strip (the silent-drop path).
      wrapped =
        "<system-reminder>\r\nThe user sent the following message:\r\n" <>
          "respond exactly \"123\"\r\n\r\n" <>
          "Please address this message and continue with your tasks.\r\n</system-reminder>"

      assert OperatorText.normalize(wrapped) == "respond exactly \"123\""
    end

    test "an empty-bodied wrapper is a legit noop, not the silent-drop bug" do
      # opencode could wrap an empty message; that normalizes to "" (nothing to
      # deliver) — but it must NOT register as the bug signature, since no real
      # operator text was lost.
      wrapped =
        "<system-reminder>\nThe user sent the following message:\n\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>"

      assert OperatorText.normalize(wrapped) == ""
      assert %{wrapped: false, dropped: false} = OperatorText.trace(wrapped, "")
    end

    test "raw text that merely echoes the wrapper phrasing is not falsely extracted" do
      # The de-anchored scan must still require the full <system-reminder>
      # envelope — a plain message that quotes the trailing instruction is
      # forwarded verbatim, not mangled.
      raw = "Please address this message and continue with your tasks."

      assert OperatorText.normalize(raw) == raw
    end
  end

  describe "trace/2 (greppable delivery-vs-drop signal)" do
    @wrapper "<system-reminder>\nThe user sent the following message:\nrespond exactly \"123\"\n\nPlease address this message and continue with your tasks.\n</system-reminder>"

    test "a recovered operator message reports wrapped=true dropped=false" do
      assert %{wrapped: true, dropped: false, in_bytes: in_bytes, out_bytes: out_bytes} =
               OperatorText.trace(@wrapper, "respond exactly \"123\"")

      assert in_bytes == byte_size(@wrapper)
      assert out_bytes > 0
    end

    test "the bug signature wrapped=true dropped=true fires only when a real message is lost" do
      # If a future regression ever made normalize forward "" for a genuine
      # wrapped message, this is the line a live --test3 grep would catch.
      assert %{wrapped: true, dropped: true} = OperatorText.trace(@wrapper, "")
    end

    test "scaffolding-only and raw text never trip the alarm" do
      scaffold = "<system-reminder>cwd changed to /tmp</system-reminder>"
      assert %{wrapped: false, dropped: false} = OperatorText.trace(scaffold, "")
      assert %{wrapped: false, dropped: false} = OperatorText.trace("hi", "hi")
    end
  end
end
