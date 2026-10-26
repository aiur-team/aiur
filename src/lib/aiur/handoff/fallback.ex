defmodule Aiur.Handoff.Fallback do
  @moduledoc false
  alias Aiur.AppServer.RelayPort
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Tmux.Socket
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.{Guardian, Store}

  @spec resume(Aiur.Orchestrator.State.t(), map()) :: Aiur.Orchestrator.State.t()
  def resume(state, %{"issue_id" => id, "identifier" => identifier} = agent) when is_binary(id) and is_binary(identifier) do
    RetryEngine.schedule_issue_retry(%{state | claimed: MapSet.put(state.claimed, id)}, id, 1, %{
      identifier: identifier,
      issue_state: get_in(agent, ["issue", "state"]),
      prior_work: true,
      handoff_fallback: true,
      worker_host: agent["worker_host"],
      delay_type: :continuation
    })
  end

  def resume(state, _agent), do: state

  @spec stop(map()) :: term()
  def stop(%{"transport" => %{"kind" => "relay", "directory" => directory} = transport}) do
    with {:ok, hello} <- RelayPort.inspect_relay(directory),
         true <- hello["spawn_nonce"] == transport["spawn_nonce"] do
      stop_relay(directory, hello)
    end
  end

  def stop(%{"transport" => %{"kind" => "repl", "pane_id" => pane, "socket" => socket}}),
    do: Socket.kill_pane(if(is_binary(socket), do: {pane, socket}, else: pane))

  def stop(_agent), do: :ok

  defp stop_relay(directory, hello) do
    generation = hello["generation"] + 1

    case RelayPort.attach(directory, generation, hello["acked_offset"]) do
      {:ok, controller} -> RelayPort.call(controller, :close)
      _ -> kill_relay(hello["relay_pid"])
    end
  end

  defp kill_relay(pid) do
    with {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- String.contains?(cmdline, "agent_relay.py") do
      Aiur.ProcessTree.graceful_kill_tree(pid)
    end
  end

  @spec restore_ownership(map(), keyword()) :: term()
  def restore_ownership(agent, opts) do
    store = Keyword.get(opts, :store, Store)
    registry = Keyword.get(opts, :registry, Ownership.Registry)
    ticket = agent["identifier"]

    with :none <- Ownership.current(ticket, registry),
         {:ok, receipt} when is_map(receipt) <- Store.get(ticket, store) do
      Guardian.restore(receipt, registry, Keyword.put(opts, :store, store))
    end
  end
end
