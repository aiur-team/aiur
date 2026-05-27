defmodule Aiur.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner

  # Regression: open_aiur_turn_streams posted the `__aiur_turn__:<id>`
  # marker SYNCHRONOUSLY in a for-loop, one POST per attached
  # opencode-serve. Each POST blocks until opencode's chat-completion
  # to our bridge returns — which, by design, holds for the entire
  # codex turn (often minutes). With Req's 30s receive_timeout, every
  # attached server stalled the loop for 30 s, and with 3 slots a
  # fresh agent waited ~90 s between dispatch and actually starting
  # its codex turn — the chat pane sat empty for that whole window.
  #
  # The fix: fire the marker posts asynchronously (Task.start) so
  # `post_aiur_turn_markers/4` returns immediately. The bridge still
  # gets its chat-completion request once opencode receives the
  # synthetic user message; we just don't block the codex turn on it.
  describe "post_aiur_turn_markers/4" do
    test "returns immediately even when post_fn would block for tens of seconds" do
      writers = [
        %{session_id: "ses_1", base_url: "http://127.0.0.1:9991"},
        %{session_id: "ses_2", base_url: "http://127.0.0.1:9992"},
        %{session_id: "ses_3", base_url: "http://127.0.0.1:9993"}
      ]

      slow_post = fn _base, _sid, _payload ->
        # Simulate Req's 30s receive_timeout — what real opencode-serves
        # do while their chat-completion to our bridge is open.
        Process.sleep(30_000)
        {:ok, %{}}
      end

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          AgentRunner.post_aiur_turn_markers("99", "tTEST", writers, slow_post)
        end)

      elapsed_ms = div(elapsed_us, 1000)

      assert elapsed_ms < 500,
             "post_aiur_turn_markers should return immediately (fire-and-forget) — took #{elapsed_ms}ms with 3 slow writers"
    end

    test "still invokes the post function for every attached writer" do
      writers = [
        %{session_id: "ses_a", base_url: "http://opencode-a"},
        %{session_id: "ses_b", base_url: "http://opencode-b"}
      ]

      parent = self()

      observing_post = fn base, sid, payload ->
        send(parent, {:posted, base, sid, payload})
        {:ok, %{}}
      end

      :ok = AgentRunner.post_aiur_turn_markers("101", "tABC", writers, observing_post)

      # The posts are asynchronous; give them a moment to land.
      assert_receive {:posted, "http://opencode-a", "ses_a", payload_a}, 1_000
      assert_receive {:posted, "http://opencode-b", "ses_b", payload_b}, 1_000

      for payload <- [payload_a, payload_b] do
        assert %{parts: [part]} = payload
        assert part["type"] == "text"
        assert part["text"] == "__aiur_turn__:tABC"
        assert part["synthetic"] == true
      end
    end

    test "swallows post errors so a failing opencode-serve does not crash agent_runner" do
      writers = [%{session_id: "ses_x", base_url: "http://gone"}]

      failing_post = fn _base, _sid, _payload -> {:error, :nxdomain} end

      # Should not raise, should return :ok, should not blow up the
      # caller (agent_runner) even though the underlying post failed.
      assert :ok = AgentRunner.post_aiur_turn_markers("42", "tFAIL", writers, failing_post)
    end

    test "empty writer list is a no-op" do
      assert :ok = AgentRunner.post_aiur_turn_markers("13", "tNONE", [], fn _, _, _ -> :ok end)
    end
  end
end
