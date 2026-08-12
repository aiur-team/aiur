defmodule Aiur.Claude.Repl.OperatorInjectTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.Repl.OperatorInject
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

  describe "send_operator_message/2 — sanitization" do
    test "collapses control bytes to spaces and sends with trailing Enter", %{tmux: tmux} do
      sess = session(tmux)
      task = Task.async(fn -> OperatorInject.send_operator_message(sess, %{kind: :text, body: "hi\nthere\x1b"}) end)

      assert_receive {:tmux_mock_out, cmd}, 1_000
      assert String.contains?(cmd, "send-keys -t %1 -l")
      # newline and escape collapsed to spaces, trimmed
      assert String.contains?(cmd, "hi there")
      refute String.contains?(cmd, "\n")
      respond(tmux, "")

      assert_receive {:tmux_mock_out, "send-keys -t %1 Enter"}, 1_000
      respond(tmux, "")

      assert {:ok, _request_id} = Task.await(task, 2_000)
    end

    test "all-control-byte body returns {:error, :empty_message} with no keys sent", %{tmux: tmux} do
      sess = session(tmux)
      result = OperatorInject.send_operator_message(sess, %{kind: :text, body: "\x00\x01\x1f\x7f"})
      assert result == {:error, :empty_message}
      refute_receive {:tmux_mock_out, _}, 200
    end

    test "non-text payload returns {:error, :invalid_message}" do
      result = OperatorInject.send_operator_message(%{tmux: nil, pane_id: "%1"}, %{kind: :binary, body: "x"})
      assert result == {:error, :invalid_message}
    end
  end

  describe "interrupt/1" do
    test "sends Ctrl+C to a minimal %{tmux:, pane_id:} map", %{tmux: tmux} do
      sess = %{tmux: tmux, pane_id: "%2"}
      task = Task.async(fn -> OperatorInject.interrupt(sess) end)

      assert_receive {:tmux_mock_out, "send-keys -t %2 C-c"}, 1_000
      respond(tmux, "")

      assert Task.await(task, 2_000) == :ok
    end

    test "returns {:error, :invalid_session} for non-map or missing pane_id" do
      assert OperatorInject.interrupt(nil) == {:error, :invalid_session}
      assert OperatorInject.interrupt(%{}) == {:error, :invalid_session}
      assert OperatorInject.interrupt(%{tmux: nil, pane_id: 123}) == {:error, :invalid_session}
    end
  end

  describe "deliver_immediate_operator_message/2" do
    test "fires on_success with request_id on delivery", %{tmux: tmux} do
      sess = session(tmux)
      parent = self()

      on_operator = fn ->
        {:deliver_text, "hello", fn r -> send(parent, {:success, r}) end, fn _ -> send(parent, :fail) end}
      end

      task = Task.async(fn -> OperatorInject.deliver_immediate_operator_message(sess, on_operator) end)

      assert_receive {:tmux_mock_out, _send_keys}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "send-keys -t %1 Enter"}, 1_000
      respond(tmux, "")

      assert_receive {:success, %{request_id: _}}, 1_000
      Task.await(task, 2_000)
    end

    test "fires on_failure on a send error" do
      bad_tmux = :nonexistent_tmux_server
      sess = %{tmux: bad_tmux, pane_id: "%99"}
      parent = self()

      on_operator = fn ->
        {:deliver_text, "hello", fn _ -> send(parent, :success) end, fn r -> send(parent, {:fail, r}) end}
      end

      OperatorInject.deliver_immediate_operator_message(sess, on_operator)
      assert_receive {:fail, _reason}, 1_000
    end

    test "returns :ok on :noop (nothing claimable)", %{tmux: tmux} do
      sess = session(tmux)
      result = OperatorInject.deliver_immediate_operator_message(sess, fn -> :noop end)
      assert result == :ok
    end
  end
end
