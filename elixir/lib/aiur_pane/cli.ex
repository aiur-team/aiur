defmodule AiurPane.CLI do
  # `wait_for_shutdown/1` blocks indefinitely on a `:DOWN` message and
  # then halts the BEAM; dialyzer flags it as no_return because it
  # never returns to a caller, but that's the intended behavior.
  @dialyzer {:no_return, wait_for_shutdown: 1}

  @moduledoc """
  Entry point for the conversation-pane subcommand.

  Invoked from a tmux pane as `bin/aiur conversation <agent-identifier>`.

  Boot sequence:
    1. Parse argv for the identifier.
    2. Start `:phoenix_pubsub` locally (matching `pool_size: 1` so the
       cross-node fan-out works against Aiur's own PubSub).
    3. Read `AIUR_NODE` from env, attempt `Node.connect/1`.
    4. Start `AiurPane.Conversation` and `wait_for_shutdown/1`.
  """

  require Logger

  alias AiurPane.Conversation

  @spec main([String.t()]) :: no_return()
  def main([identifier | _rest]) when is_binary(identifier) and identifier != "" do
    _ = Application.ensure_all_started(:logger)
    _ = Aiur.LogFile.configure_level()
    _ = Application.ensure_all_started(:phoenix_pubsub)
    _ = Application.ensure_started(:aiur_pubsub_pane)

    start_pubsub()

    Logger.debug("AiurPane.CLI starting for identifier=#{inspect(identifier)}")

    {:ok, pid} = Conversation.start_link(identifier, [])

    wait_for_shutdown(pid)
  end

  def main(_argv) do
    IO.puts(:stderr, "Usage: aiur conversation <agent-identifier>")
    System.halt(64)
  end

  defp start_pubsub do
    case Process.whereis(Aiur.PubSub) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Phoenix.PubSub.Supervisor.start_link(name: Aiur.PubSub, pool_size: 1) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
    end
  end

  defp wait_for_shutdown(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        case reason do
          :normal -> System.halt(0)
          _ -> System.halt(1)
        end
    end
  end
end
