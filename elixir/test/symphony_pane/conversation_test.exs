defmodule SymphonyPane.ConversationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentEvents, AgentPubSub}
  alias SymphonyPane.Conversation

  defp start_pane(identifier) do
    parent = self()

    {:ok, pid} =
      GenServer.start_link(
        Conversation,
        {identifier,
         [
           skip_raw_mode: true,
           write_fun: fn d -> send(parent, {:frame, IO.iodata_to_binary(d)}) end,
           input_fun: fn -> :eof end
         ]}
      )

    # Drain the initial render.
    assert_receive {:frame, _}, 500

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          # Tolerate the narrow race between `Process.alive?/1` and
          # `GenServer.stop/3`'s monitor: PubSub-driven tests can finish
          # rendering after the test body returns, and the pane may already
          # be mid-shutdown when `stop/3` reaches it.
          :exit, _ -> :ok
        end
      end
    end)

    pid
  end

  defp visible(text) do
    Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, text, "")
  end

  test "renders the identifier in the initial frame" do
    parent = self()

    {:ok, pid} =
      GenServer.start_link(
        Conversation,
        {"MT-XYZ",
         [
           skip_raw_mode: true,
           write_fun: fn d -> send(parent, {:frame, IO.iodata_to_binary(d)}) end,
           input_fun: fn -> :eof end
         ]}
      )

    assert_receive {:frame, frame}, 500
    assert visible(frame) =~ "Symphony — MT-XYZ"

    GenServer.stop(pid)
  end

  test "transcript_event appends to state and re-renders" do
    pid = start_pane("MT-T")
    event = AgentEvents.transcript_event(:assistant, "hello there")

    send(pid, {:transcript_event, event})

    assert_receive {:frame, frame}, 500
    assert visible(frame) =~ "[agent]"
    assert visible(frame) =~ "hello there"

    state = :sys.get_state(pid)
    assert state.transcript == [event]
  end

  test "input bytes update the composer and re-render" do
    pid = start_pane("MT-I")

    send(pid, {:input, "h"})
    send(pid, {:input, "i"})

    assert_receive {:frame, _}, 500

    state = :sys.get_state(pid)
    assert state.composer.buffer == "hi"
  end

  test "alert message appends a system-line into the transcript" do
    pid = start_pane("MT-A")

    send(pid, {:alert, AgentEvents.alert_event("demo.heads_up", "look")})

    assert_receive {:frame, frame}, 500
    assert visible(frame) =~ "[alert]"
    assert visible(frame) =~ "demo.heads_up: look"

    state = :sys.get_state(pid)
    assert length(state.transcript) == 1
  end

  test "subscribes locally and renders broadcasts on the agent topic" do
    identifier = "MT-PUBSUB-#{System.unique_integer([:positive])}"
    pid = start_pane(identifier)

    AgentPubSub.broadcast_transcript(
      identifier,
      AgentEvents.transcript_event(:assistant, "hello via pubsub")
    )

    assert_receive {:frame, frame}, 500
    assert visible(frame) =~ "[agent]"
    assert visible(frame) =~ "hello via pubsub"

    state = :sys.get_state(pid)
    assert Enum.any?(state.transcript, fn e -> e.body == "hello via pubsub" end)
  end

  test "submit success: composer clears with no local echo; broadcast renders user line" do
    identifier = "MT-SUBMIT-#{System.unique_integer([:positive])}"
    pid = start_pane(identifier)

    send(pid, {:input, "h"})
    send(pid, {:input, "i"})
    send(pid, {:input, "\r"})

    # Drain renders triggered by each input + the submit reset.
    for _ <- 1..3, do: assert_receive({:frame, _}, 500)

    state = :sys.get_state(pid)
    assert state.composer.buffer == ""
    # No optimistic echo — transcript stays empty until the broadcast lands.
    assert state.transcript == []

    # Simulate the broadcast that `AgentChat.send/3` would emit on `{:ok, _}`.
    AgentPubSub.broadcast_transcript(identifier, AgentEvents.transcript_event(:user, "hi"))

    assert_receive {:frame, frame}, 500
    assert visible(frame) =~ "[user]"
    assert visible(frame) =~ "hi"
  end

  test "submit error: appends a system transcript event when RPC fails" do
    identifier = "MT-ERR-#{System.unique_integer([:positive])}"
    parent = self()
    bogus_node = :"nonexistent-#{System.unique_integer([:positive])}@127.0.0.1"

    {:ok, pid} =
      GenServer.start_link(
        Conversation,
        {identifier,
         [
           skip_raw_mode: true,
           write_fun: fn d -> send(parent, {:frame, IO.iodata_to_binary(d)}) end,
           input_fun: fn -> :eof end,
           symphony_node: bogus_node
         ]}
      )

    assert_receive {:frame, _}, 500

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    send(pid, {:input, "x"})
    send(pid, {:input, "\r"})

    # Wait for the rpc.call to fail and the system event to render.
    assert_receive {:frame, frame}, 3_000
    raw_frame = frame

    # The rendered frame should include either the typed char render or the
    # failure system message. Keep draining until we see "send failed:".
    failure_frame =
      Enum.reduce_while(1..5, raw_frame, fn _i, acc ->
        if visible(acc) =~ "send failed:" do
          {:halt, acc}
        else
          case_receive_next()
        end
      end)

    assert visible(failure_frame) =~ "send failed:"

    state = :sys.get_state(pid)
    assert state.composer.buffer == ""

    assert Enum.any?(state.transcript, fn e ->
             e[:role] == :system and String.contains?(e[:body] || "", "send failed:")
           end)
  end

  defp case_receive_next do
    receive do
      {:frame, frame} -> {:cont, frame}
    after
      3_000 -> {:halt, ""}
    end
  end
end
