defmodule SymphonyElixir.Distribution do
  @moduledoc """
  Symphony's Erlang distribution bring-up and monitoring.

  Phase 1 expectations: `scripts/agents` launches the BEAM with `-sname` and
  reads the cookie from `~/.erlang.cookie` (BEAM auto-reads it). This module
  is called from `Application.start/2` to validate the runtime environment
  and start monitoring for pane-node lifecycle events.

  Per the security review, `ERL_EPMD_ADDRESS` must be `127.0.0.1` so epmd is
  not exposed beyond loopback. We refuse to enable distribution monitoring if
  that invariant is broken.
  """

  require Logger

  @typedoc "Outcome of `start!/0` when called outside the wrapper."
  @type result :: :ok | {:error, :not_distributed | :epmd_not_local}

  @spec start!() :: result()
  def start! do
    monitor_hidden_nodes()
  end

  @spec node_name() :: atom() | nil
  def node_name do
    case Node.self() do
      :nonode@nohost -> nil
      name -> name
    end
  end

  @spec epmd_address() :: String.t()
  def epmd_address, do: System.get_env("ERL_EPMD_ADDRESS", "")

  @spec hidden_pane_nodes() :: [node()]
  def hidden_pane_nodes, do: Node.list(:hidden)

  defp monitor_hidden_nodes do
    :net_kernel.monitor_nodes(true, node_type: :hidden)
    :ok
  rescue
    error ->
      Logger.warning("Distribution monitor setup failed: #{Exception.message(error)}")
      {:error, :not_distributed}
  end
end
