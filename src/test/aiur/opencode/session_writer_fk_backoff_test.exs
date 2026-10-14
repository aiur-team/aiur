defmodule Aiur.Opencode.SessionWriterFkBackoffTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.SessionWriter

  describe "FOREIGN KEY threshold backoff" do
    test "first FK violation bumps counter from 0 → 1, does not stop" do
      state = %SessionWriter{
        identifier: "fk-test-1",
        session_id: "ses_fk_1",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 0
      }

      reason = %Exqlite.Error{message: "FOREIGN KEY constraint failed"}

      assert {:noreply, %SessionWriter{consecutive_fk_failures: 1}} =
               SessionWriter.handle_write_failure_for_test(state, reason)
    end

    test "5th consecutive FK violation stops the writer with :normal" do
      state = %SessionWriter{
        identifier: "fk-test-2",
        session_id: "ses_fk_2",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 4
      }

      reason = %Exqlite.Error{message: "FOREIGN KEY constraint failed"}

      assert {:stop, :normal, %SessionWriter{consecutive_fk_failures: 5}} =
               SessionWriter.handle_write_failure_for_test(state, reason)
    end

    test "non-FK error leaves the counter unchanged and does not stop" do
      state = %SessionWriter{
        identifier: "fk-test-3",
        session_id: "ses_fk_3",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 3
      }

      assert {:noreply, %SessionWriter{consecutive_fk_failures: 3}} =
               SessionWriter.handle_write_failure_for_test(state, :network_timeout)
    end

    test "reset_fk_failures zeroes a non-zero counter" do
      state = %SessionWriter{
        identifier: "fk-test-4",
        session_id: "ses_fk_4",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 3
      }

      assert %SessionWriter{consecutive_fk_failures: 0} =
               SessionWriter.reset_fk_failures_for_test(state)
    end

    test "reset is a no-op on a counter already at 0" do
      state = %SessionWriter{
        identifier: "fk-test-5",
        session_id: "ses_fk_5",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 0
      }

      # Same struct identity preserved when no work needed.
      assert state == SessionWriter.reset_fk_failures_for_test(state)
    end

    test "interleaved FK / success / FK pattern correctly resets between bursts" do
      state = %SessionWriter{
        identifier: "fk-test-6",
        session_id: "ses_fk_6",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 4
      }

      reason = %Exqlite.Error{message: "FOREIGN KEY constraint failed"}

      # Success resets.
      state = SessionWriter.reset_fk_failures_for_test(state)
      assert state.consecutive_fk_failures == 0

      # 4 more FKs do not trip threshold.
      state =
        Enum.reduce(1..4, state, fn _, acc ->
          {:noreply, next} = SessionWriter.handle_write_failure_for_test(acc, reason)
          next
        end)

      assert state.consecutive_fk_failures == 4

      # Another success resets again — a single isolated FK after this
      # must NOT trip the threshold even though we had 4 FKs earlier.
      state = SessionWriter.reset_fk_failures_for_test(state)

      assert {:noreply, %SessionWriter{consecutive_fk_failures: 1}} =
               SessionWriter.handle_write_failure_for_test(state, reason)
    end
  end
end
