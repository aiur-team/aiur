defmodule SymphonyPane.CLI do
  @moduledoc """
  Entry point for the conversation-pane subcommand.

  Invoked from a tmux pane as `bin/symphony conversation <agent-identifier>`.

  Boot sequence:
    1. Parse argv for the identifier.
    2. Start `:phoenix_pubsub` locally (matching `pool_size: 1` so the
       cross-node fan-out works against Symphony's own PubSub).
    3. Read `SYMPHONY_NODE` from env, attempt `Node.connect/1`.
    4. Start `SymphonyPane.Conversation` and `wait_for_shutdown/1`.
  """

  require Logger

  alias SymphonyPane.Conversation

  @spec main([String.t()]) :: no_return()
  def main([identifier | _rest]) when is_binary(identifier) and identifier != "" do
    _ = Application.ensure_all_started(:logger)
    _ = SymphonyElixir.LogFile.configure_level()
    _ = Application.ensure_all_started(:phoenix_pubsub)
    _ = Application.ensure_started(:symphony_elixir_pubsub_pane)

    start_pubsub()

    Logger.debug("SymphonyPane.CLI starting for identifier=#{inspect(identifier)}")

    {:ok, pid} = Conversation.start_link(identifier, [])

    wait_for_shutdown(pid)
  end

  def main(_argv) do
    IO.puts(:stderr, "Usage: symphony conversation <agent-identifier>")
    System.halt(64)
  end

  defp start_pubsub do
    case Process.whereis(SymphonyElixir.PubSub) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Phoenix.PubSub.Supervisor.start_link(name: SymphonyElixir.PubSub, pool_size: 1) do
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
