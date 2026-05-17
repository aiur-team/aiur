defmodule SymphonyElixir.Tmux.ProtocolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tmux.Protocol

  describe "parse/2 with command results" do
    test "captures a single-line success response" do
      state = Protocol.new_state()
      {_state, events} = Protocol.parse(state, "%begin 1234 7 0\nhello\n%end 1234 7 0\n")

      assert events == [{:command_result, 7, :ok, ["hello"]}]
    end

    test "captures a multi-line success response" do
      {_state, events} =
        Protocol.parse(Protocol.new_state(), "%begin 1 2 0\nline-a\nline-b\n%end 1 2 0\n")

      assert events == [{:command_result, 2, :ok, ["line-a", "line-b"]}]
    end

    test "captures an error response" do
      {_state, events} =
        Protocol.parse(Protocol.new_state(), "%begin 1 3 0\nbad\n%error 1 3 0\n")

      assert events == [{:command_result, 3, :error, ["bad"]}]
    end

    test "buffers across chunks" do
      {state, evts1} = Protocol.parse(Protocol.new_state(), "%begin 1 4 0\nbody")
      assert evts1 == []
      {_state, evts2} = Protocol.parse(state, "\n%end 1 4 0\n")
      assert evts2 == [{:command_result, 4, :ok, ["body"]}]
    end
  end

  describe "parse/2 with notifications" do
    test "parses %pane-died" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%pane-died %42\n")
      assert events == [{:notification, :pane_died, "%42"}]
    end

    test "parses %window-pane-changed" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%window-pane-changed @1 %42\n")
      assert events == [{:notification, :window_pane_changed, "@1", "%42"}]
    end

    test "parses %client-detached" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%client-detached\n")
      assert events == [{:notification, :client_detached}]
    end

    test "parses %session-changed" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%session-changed $1 main\n")
      assert events == [{:notification, :session_changed, "$1", "main"}]
    end

    test "parses %output" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%output %1 hello\n")
      assert events == [{:notification, :output, "%1", "hello"}]
    end

    test "parses %exit with no reason" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%exit\n")
      assert events == [{:notification, :exit, nil}]
    end

    test "parses %exit with reason" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%exit goodbye\n")
      assert events == [{:notification, :exit, "goodbye"}]
    end

    test "returns unknown notifications verbatim instead of crashing" do
      {_state, events} = Protocol.parse(Protocol.new_state(), "%something-new payload\n")
      assert events == [{:unknown_notification, "%something-new payload"}]
    end
  end

  describe "parse/2 mixed streams" do
    test "interleaves notifications and command results" do
      stream =
        Enum.join(
          [
            "%pane-died %5",
            "%begin 1 1 0",
            "ok",
            "%end 1 1 0",
            "%window-pane-changed @1 %6"
          ],
          "\n"
        ) <> "\n"

      {_state, events} = Protocol.parse(Protocol.new_state(), stream)

      assert events == [
               {:notification, :pane_died, "%5"},
               {:command_result, 1, :ok, ["ok"]},
               {:notification, :window_pane_changed, "@1", "%6"}
             ]
    end
  end
end
