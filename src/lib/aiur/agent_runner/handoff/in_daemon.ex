defmodule Aiur.AgentRunner.Handoff.InDaemon do
  @moduledoc """
  Handoff bridge for backends whose provider runs inside the daemon process.

  An in-process HTTP backend (the OpenAI-compatible providers) has no child
  process or pane for a successor daemon to re-attach to: its conversation lives
  in this daemon's own `Aiur.OpenAICompat.Session` agent. A `restart
  --keep-agents` therefore snapshots the conversation at a safe step boundary,
  and the successor starts a fresh session from it. The runner-side barrier and
  record plumbing live in `Aiur.AgentRunner.Handoff`; this module holds only the
  provider-in-daemon specifics so that file stays readable.
  """

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.CodingAgent

  @transport_kind "in_daemon"

  @doc "Honor a daemon handoff hold at an in-turn safe step boundary."
  @spec checkpoint(map(), map() | nil) :: :continue
  def checkpoint(session, state) do
    receive do
      :handoff_hold ->
        Process.put(:handoff_hold, true)
        checkpoint(session, state)

      :handoff_abort ->
        Process.delete(:handoff_hold)
        :continue

      {:handoff_abort, from, ref} ->
        Process.delete(:handoff_hold)
        send(from, {:handoff_aborted, ref})
        :continue

      {:handoff_snapshot, from, ref} ->
        if Process.get(:handoff_hold), do: RunnerHandoff.capture(session, state, from, ref)
        :continue
    after
      0 -> :continue
    end
  end

  @doc "Whether this backend declares in-daemon handoff support."
  @spec backend?(term()) :: boolean()
  def backend?(backend), do: CodingAgent.handoff_kind(backend) == :in_daemon

  @doc """
  Serialize a session's conversation into a handoff transport.

  `state` is the run loop's in-flight state when the handoff lands mid-turn (the
  `Session` agent is only updated when a turn commits); `nil` at a turn boundary
  reads the committed session instead. An unknown backend key never raises: the
  record carries an unsupported transport and the preflight reports a fallback.
  """
  @spec detach(map(), map() | nil) :: {:ok, map()} | :unsupported
  def detach(session, state) do
    with adapter when is_atom(adapter) and not is_nil(adapter) <- adapter_for(session[:backend]),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :handoff_state, 2),
         {:ok, provider_state} <- adapter.handoff_state(session, state) do
      {:ok,
       %{
         "kind" => @transport_kind,
         "provider_state" => RunnerHandoff.encode(provider_state),
         "os_pid" => session[:os_pid]
       }}
    else
      _ -> failure(session[:backend], session)
    end
  end

  @doc "Start the successor daemon's session from a record's saved conversation."
  @spec attach(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach(record, opts) do
    with adapter when is_atom(adapter) and not is_nil(adapter) <- adapter_for(record["backend"]),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :adopt_handoff_session, 2) do
      adapter.adopt_handoff_session(record, opts)
    else
      _ -> {:error, :unsupported_handoff_backend}
    end
  end

  @doc "Whether the snapshot was taken mid-turn, so adoption continues that turn."
  @spec interrupted?(map()) :: boolean()
  def interrupted?(%{"transport" => %{"provider_state" => encoded}}) when is_binary(encoded) do
    match?(%{"interrupted" => true}, RunnerHandoff.decode(encoded))
  rescue
    _ -> false
  end

  def interrupted?(_record), do: false

  @doc """
  Continue a turn the handoff interrupted.

  The restored conversation already holds that turn's prompt and tool results, so
  re-running the cold-start prompt would duplicate the brief.
  """
  @spec resume_turn(map(), map(), keyword()) :: term()
  def resume_turn(session, record, opts),
    do: CodingAgent.adapter(record["backend"]).resume_handoff_turn(session, opts)

  defp failure(backend, session) do
    if backend?(backend),
      do: {:ok, %{"kind" => "in_daemon_failed", "os_pid" => session[:os_pid]}},
      else: :unsupported
  end

  defp adapter_for(backend) do
    case Map.get(CodingAgent.backends(), backend) do
      %{adapter: adapter} -> adapter
      _ -> nil
    end
  end
end
