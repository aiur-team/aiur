defmodule Aiur.Claude.Repl.PromptSubmitTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.Repl.PromptSubmit
  alias Aiur.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")
    {:ok, _pid} = start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})
    %{tmux: name}
  end

  defp respond(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
  end

  defp session(tmux), do: %{tmux: tmux, pane_id: "%1"}

  # Drain all pending tmux commands, flunking if clear_input is ever sent.
  defp drain_no_clear_input(tmux, done_msg) do
    receive do
      ^done_msg ->
        :done

      {:tmux_mock_out, cmd} ->
        if String.contains?(cmd, "send-keys -t %1 C-u") do
          flunk("clear_input (C-u) must never be sent on the submit/3 (hook/RC) path, got: #{cmd}")
        end

        respond(tmux, "")
        drain_no_clear_input(tmux, done_msg)
    after
      3_000 -> flunk("timeout waiting for #{inspect(done_msg)}")
    end
  end

  describe "submit/3 — hook/RC path" do
    test "pastes, polls for chip or prefix, sends Enter; NO clear_input ever", %{tmux: tmux} do
      sess = session(tmux)
      ref = make_ref()
      parent = self()

      task =
        Task.async(fn ->
          result = PromptSubmit.submit(sess, "hello world", [])
          send(parent, {ref, :done})
          result
        end)

      # paste_text sends two commands: load-buffer (from temp file) then paste-buffer
      assert_receive {:tmux_mock_out, "load-buffer" <> _}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "paste-buffer" <> _}, 1_000
      respond(tmux, "")

      # capture-pane poll: first no echo
      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
      respond(tmux, "❯\n")

      # capture-pane poll: echo appears
      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
      respond(tmux, "❯\nhello world\n")

      # Enter sent after echo confirmed
      assert_receive {:tmux_mock_out, "send-keys -t %1 Enter"}, 1_000
      respond(tmux, "")

      drain_no_clear_input(tmux, {ref, :done})
      assert Task.await(task, 3_000) == :ok
    end

    test "sends Enter even when echo times out (best-effort, no error)", %{tmux: tmux} do
      sess = session(tmux)
      parent = self()
      ref = make_ref()

      task =
        Task.async(fn ->
          # 0ms confirm budget: times out on first poll
          result = PromptSubmit.submit(sess, "prompt", prompt_confirm_ms: 0)
          send(parent, {ref, :done})
          result
        end)

      # paste_text: load-buffer then paste-buffer
      assert_receive {:tmux_mock_out, "load-buffer" <> _}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "paste-buffer" <> _}, 1_000
      respond(tmux, "")

      # one capture-pane → no echo, deadline already expired
      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
      respond(tmux, "❯\n")

      # Enter still fires
      assert_receive {:tmux_mock_out, "send-keys -t %1 Enter"}, 1_000
      respond(tmux, "")

      drain_no_clear_input(tmux, {ref, :done})
      assert Task.await(task, 3_000) == :ok
    end

    test "paste_indicator chip matches as landed", %{tmux: tmux} do
      sess = session(tmux)
      task = Task.async(fn -> PromptSubmit.submit(sess, String.duplicate("a ", 60), []) end)

      assert_receive {:tmux_mock_out, "load-buffer" <> _}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "paste-buffer" <> _}, 1_000
      respond(tmux, "")

      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
      respond(tmux, "[Pasted text +3 lines]\n")

      assert_receive {:tmux_mock_out, "send-keys -t %1 Enter"}, 1_000
      respond(tmux, "")

      assert Task.await(task, 2_000) == :ok
    end
  end

  describe "send/3 — transcript path" do
    test "re-pastes after clear when echo is missing, returns :ok when echo lands", %{tmux: tmux} do
      sess = session(tmux)
      task = Task.async(fn -> PromptSubmit.send(sess, "prompt here", prompt_retype_ms: 0) end)

      # First paste: load-buffer then paste-buffer
      assert_receive {:tmux_mock_out, "load-buffer" <> _}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "paste-buffer" <> _}, 1_000
      respond(tmux, "")

      # First poll: no echo
      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
      respond(tmux, "❯\n")

      # retype_ms elapsed: clear_input then re-paste (again two commands)
      assert_receive {:tmux_mock_out, "send-keys -t %1 C-u"}, 1_000
      respond(tmux, "")

      assert_receive {:tmux_mock_out, "load-buffer" <> _}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "paste-buffer" <> _}, 1_000
      respond(tmux, "")

      # Echo now lands
      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
      respond(tmux, "❯\nprompt here\n")

      # Enter submitted
      assert_receive {:tmux_mock_out, "send-keys -t %1 Enter"}, 1_000
      respond(tmux, "")

      assert Task.await(task, 2_000) == :ok
    end

    test "returns {:error, :prompt_not_delivered} when budget expires with no Enter sent", %{tmux: tmux} do
      sess = session(tmux)

      task =
        Task.async(fn ->
          PromptSubmit.send(sess, "never lands", prompt_confirm_ms: 0, prompt_retype_ms: 100)
        end)

      # First paste: load-buffer then paste-buffer
      assert_receive {:tmux_mock_out, "load-buffer" <> _}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "paste-buffer" <> _}, 1_000
      respond(tmux, "")

      # Deadline already expired on first poll
      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
      respond(tmux, "❯\n")

      # No Enter should be sent
      refute_receive {:tmux_mock_out, "send-keys -t %1 Enter"}, 200

      assert Task.await(task, 2_000) == {:error, :prompt_not_delivered}
    end
  end
end
