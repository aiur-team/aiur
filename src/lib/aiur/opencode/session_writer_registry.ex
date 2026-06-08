defmodule Aiur.Opencode.SessionWriterRegistry do
  @moduledoc """
  Registry for `Aiur.Opencode.SessionWriter` processes.

  Keyed by agent `identifier` with duplicate-key registry storage: one
  writer per `(identifier, base_url)` pair. opencode sessions are not
  portable across serves — each slot's serve owns its own session for a
  given agent, and the writer that pushes transcript events to that
  serve must use that serve's session_id.

  `ensure/2` is the only public mutator. Aiur tracks every session it
  creates so shutdown can `DELETE /session/<id>` for each.
  """

  alias Aiur.Opencode.{ApiClient, Config, SessionSupervisor, SessionWriter}

  @registry __MODULE__.Registry

  @doc """
  Idempotently ensure a `SessionWriter` is running for `(identifier, base_url)`
  and an opencode session exists in that serve.

  Each (identifier, base_url) pair gets its OWN writer + session. Session
  ids are per-serve: opencode sessions are not portable across serves
  even when those serves share a SQLite database (the session carries
  the serve's bridge token / workspace directory). Reusing one serve's
  session_id against a different serve produced silent attach death and
  FOREIGN KEY constraint failures.
  """
  @spec ensure(String.t(), String.t()) ::
          {:ok, %{session_id: String.t(), writer_pid: pid()}} | {:error, term()}
  def ensure(identifier, base_url) when is_binary(identifier) and is_binary(base_url) do
    case lookup(identifier, base_url) do
      {:ok, _} = found ->
        found

      :not_found ->
        with {:ok, session_id} <- create_session(identifier, base_url),
             {:ok, pid} <- start_writer(identifier, session_id, base_url) do
          {:ok, %{session_id: session_id, writer_pid: pid}}
        end
    end
  end

  @doc """
  Look up the writer + session for `(identifier, base_url)`. With the
  registry's duplicate-key keying, there may be multiple writers per
  identifier (one per serve); this scans for the one bound to `base_url`.
  """
  @spec lookup(String.t(), String.t()) ::
          {:ok, %{session_id: String.t(), writer_pid: pid()}} | :not_found
  def lookup(identifier, base_url) when is_binary(identifier) and is_binary(base_url) do
    @registry
    |> Registry.lookup(identifier)
    |> Enum.find_value(:not_found, fn
      {pid, %{session_id: sid, base_url: ^base_url}} when is_pid(pid) and is_binary(sid) ->
        if Process.alive?(pid), do: {:ok, %{session_id: sid, writer_pid: pid}}

      _ ->
        nil
    end)
  end

  @doc """
  Return any writer for `identifier`, regardless of base_url. Used by
  chat-completion replay where the message id is globally unique so any
  writer's session_id lets us read it back.
  """
  @spec lookup(String.t()) :: {:ok, %{session_id: String.t(), writer_pid: pid()}} | :not_found
  def lookup(identifier) when is_binary(identifier) do
    @registry
    |> Registry.lookup(identifier)
    |> Enum.find_value(:not_found, fn
      {pid, %{session_id: sid}} when is_pid(pid) and is_binary(sid) ->
        if Process.alive?(pid), do: {:ok, %{session_id: sid, writer_pid: pid}}

      _ ->
        nil
    end)
  end

  @doc """
  Enumerate every (identifier, session_id, base_url, writer_pid) tracked
  here. Used by `Aiur.Shutdown.shutdown/2` to walk the registry and
  DELETE each session before halting.
  """
  @spec all() :: [
          %{
            identifier: String.t(),
            session_id: String.t(),
            base_url: String.t(),
            writer_pid: pid()
          }
        ]
  def all do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.flat_map(fn
      {identifier, pid, %{session_id: sid, base_url: url}} ->
        [%{identifier: identifier, session_id: sid, base_url: url, writer_pid: pid}]

      _ ->
        []
    end)
  end

  @doc """
  All live (session_id, base_url) pairs registered for `identifier`. Used
  by `Aiur.AgentRunner` to fan a `__aiur_turn__:<id>` marker prompt out
  to every attached opencode-serve at the start of a codex turn so each
  chat-pane TUI opens a chat-completion request that the bridge can
  hold open and stream live.
  """
  @spec attached(String.t()) :: [%{session_id: String.t(), base_url: String.t()}]
  def attached(identifier) when is_binary(identifier) do
    @registry
    |> Registry.lookup(identifier)
    |> Enum.flat_map(fn
      {pid, %{session_id: sid, base_url: url}} when is_pid(pid) and is_binary(sid) ->
        if Process.alive?(pid), do: [%{session_id: sid, base_url: url}], else: []

      _ ->
        []
    end)
  end

  @doc """
  Synchronously walk the registry: stop each writer and DELETE its
  opencode session via `ApiClient.delete_session/2`. Idempotent — both
  `Aiur.Shutdown.shutdown/2` and `Aiur.Application.stop/1` may call this.

  Best-effort: individual failures are logged and skipped; the call
  returns when every entry has been attempted or `timeout_ms` elapses.
  """
  @spec delete_all(non_neg_integer()) :: :ok
  def delete_all(timeout_ms \\ 5_000) when is_integer(timeout_ms) and timeout_ms >= 0 do
    entries = all()

    if entries == [] do
      :ok
    else
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      Enum.each(entries, &drain_entry(&1, deadline))
      :ok
    end
  end

  # --- internals ----------------------------------------------------------

  defp drain_entry(%{session_id: session_id, base_url: base_url, writer_pid: pid}, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining > 0 do
      _ = maybe_delete_session(base_url, session_id)
      _ = DynamicSupervisor.terminate_child(SessionSupervisor, pid)
    end
  end

  defp create_session(identifier, base_url) do
    safe_id = Config.safe_identifier(identifier)
    directory = workspace_for(identifier)
    _ = File.mkdir_p(directory)

    # Per-agent workspace dirs serve as opencode's `directory=` for
    # session creation only (file picker / sidebar). They no longer
    # need a per-agent opencode.json — the slot's workspace owns the
    # provider config, and the slot's models map already declares this
    # identifier (see `WorkspaceSetup.materialize_slot/5`).
    opts = [
      model: %{providerID: "aiur", id: "issue-#{safe_id}"},
      directory: directory
    ]

    case ApiClient.create_session(base_url, identifier, opts) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, %{id: id}} when is_binary(id) -> {:ok, id}
      {:ok, %{"session" => %{"id" => id}}} when is_binary(id) -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _reason} = err -> err
    end
  end

  defp start_writer(identifier, session_id, base_url) do
    spec = %{
      id: {SessionWriter, identifier},
      start: {SessionWriter, :start_link, [%{identifier: identifier, session_id: session_id, base_url: base_url}]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(SessionSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = err -> err
    end
  end

  defp workspace_for(identifier) do
    Aiur.Config.workspace_root()
    |> Path.expand()
    |> Path.join(Aiur.Opencode.Config.safe_identifier(identifier))
  end

  defp maybe_delete_session(nil, _session_id), do: :ok
  defp maybe_delete_session(base_url, session_id), do: ApiClient.delete_session(base_url, session_id)
end
