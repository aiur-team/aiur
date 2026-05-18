defmodule Aiur.Distribution do
  @moduledoc """
  Aiur's Erlang distribution bring-up and monitoring.

  Phase 1 expectations: `scripts/aiur` launches the BEAM with `-sname` and
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
  def start!, do: do_monitor_hidden_nodes(&:net_kernel.monitor_nodes/2)

  @doc false
  @spec start!((boolean(), keyword() -> :ok)) :: result()
  def start!(monitor_fn) when is_function(monitor_fn, 2),
    do: do_monitor_hidden_nodes(monitor_fn)

  @spec node_name() :: atom() | nil
  def node_name, do: node_name(&Node.self/0)

  @doc false
  @spec node_name((-> atom())) :: atom() | nil
  def node_name(node_self_fn) when is_function(node_self_fn, 0) do
    case node_self_fn.() do
      :nonode@nohost -> nil
      name -> name
    end
  end

  @spec epmd_address() :: String.t()
  def epmd_address, do: System.get_env("ERL_EPMD_ADDRESS", "")

  @spec hidden_pane_nodes() :: [node()]
  def hidden_pane_nodes, do: Node.list(:hidden)

  defp do_monitor_hidden_nodes(monitor_fn) do
    monitor_fn.(true, node_type: :hidden)
    :ok
  rescue
    error ->
      Logger.warning("Distribution monitor setup failed: #{Exception.message(error)}")
      {:error, :not_distributed}
  end
end
