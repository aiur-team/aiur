defmodule Aiur.AgentRunner.SessionResume do
  @moduledoc false

  require Logger

  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.SessionHandle

  @type worker_host :: String.t() | nil

  # Load the prior thread id to resume from, or nil for a clean start. Only a
  # resumable backend running on the LOCAL worker can resume — the durable
  # resume artifact is host-local (codex's rollout in ~/.codex, the claude REPL's
  # transcript jsonl in ~/.claude/projects), so a remote worker cannot reattach
  # to it. Disk is only touched when a resume could apply.
  @doc false
  @spec load_resume_thread_id(String.t(), worker_host(), String.t() | nil) :: String.t() | nil
  def load_resume_thread_id(backend, worker_host, identifier) do
    if worker_host == nil and CodingAgent.resumable?(backend) do
      resume_thread_id(backend, worker_host, SessionHandle.load(identifier, backend))
    else
      nil
    end
  end

  # The thread id to resume, or nil for a clean start, given the resolved
  # backend, the worker host, and the result of `SessionHandle.load/3`. Resume
  # applies only to a resumable backend on the local worker with a valid
  # handle; everything else (no handle, non-resumable backend, remote worker)
  # cleanly starts fresh.
  @doc false
  @spec resume_thread_id(String.t(), worker_host(), {:ok, map()} | :none) :: String.t() | nil
  def resume_thread_id(backend, nil, {:ok, %{thread_id: thread_id}}) when is_binary(thread_id) do
    if CodingAgent.resumable?(backend), do: thread_id, else: nil
  end

  def resume_thread_id(_backend, _worker_host, _handle), do: nil

  @doc false
  @spec maybe_put_resume_thread_id(keyword(), String.t() | nil) :: keyword()
  def maybe_put_resume_thread_id(opts, nil), do: opts

  def maybe_put_resume_thread_id(opts, thread_id) when is_binary(thread_id),
    do: Keyword.put(opts, :resume_thread_id, thread_id)

  # Whether the adapter resumed a prior thread (vs a fresh/fallback clean
  # start). Drives the first-turn prompt choice — a resumed thread continues
  # rather than re-discovering the work.
  @doc false
  @spec session_resumed?(map()) :: boolean()
  def session_resumed?(%{resumed: true}), do: true
  def session_resumed?(_session), do: false

  # A very large resumed thread can lose its transport at every turn start
  # (#4561), and each retry resumes the same thread again. After this many
  # consecutive dispatches whose resumed first turn failed to start with
  # `port_closed`, forget the thread so the next dispatch starts fresh from the
  # workpad and branch.
  @resume_port_closed_limit 2

  # Called with the result of a dispatch's FIRST turn only: a later turn's
  # port loss is not a resume failure. Returns `result` unchanged. Best-effort:
  # a handle write failure must never change the run's outcome.
  @doc false
  @spec track_resume_turn_start(map(), String.t(), term(), keyword()) :: term()
  def track_resume_turn_start(session, identifier, result, opts \\ []) do
    note_resume_turn_start(session, identifier, result, opts)
    result
  rescue
    error ->
      Logger.warning("Could not track resumed turn start for #{identifier}: #{inspect(error)}")
      result
  end

  defp note_resume_turn_start(%{resumed: true, thread_id: thread_id}, identifier, {:error, {:turn_start_failed, :port_closed}}, opts)
       when is_binary(thread_id) do
    count = SessionHandle.record_resume_failure(identifier, thread_id, opts)

    if count >= @resume_port_closed_limit do
      Logger.warning("Resumed thread lost its transport at turn start #{count} times for #{identifier} thread_id=#{thread_id}; next attempt starts a fresh session")
      SessionHandle.drop_thread(identifier, opts)
    end
  end

  defp note_resume_turn_start(%{resumed: true}, identifier, _result, opts),
    do: SessionHandle.reset_resume_failures(identifier, opts)

  defp note_resume_turn_start(_session, _identifier, _result, _opts), do: :ok

  # First-turn prompt opts. A resumed thread already carries the original task
  # and full prior turn history, so it continues rather than replaying the
  # cold-start prompt. A fresh session that replaced an abandoned thread has no
  # such history but does have prior work (branch, workspace, workpad), so it
  # gets the continuation prompt with a note about the abandoned thread.
  @doc false
  @spec put_first_turn_opts(keyword(), map(), String.t(), keyword()) :: keyword()
  def put_first_turn_opts(opts, session, identifier, handle_opts \\ []) do
    resumed? = session_resumed?(session)
    opts = Keyword.put(opts, :resumed, resumed?)

    if not resumed? and SessionHandle.abandoned_thread?(identifier, handle_opts),
      do: Keyword.merge(opts, prior_work: true, abandoned_thread: true),
      else: opts
  end

  # Session-lifecycle log carrying full issue context (per docs/logging.md,
  # which scopes issue-context start/completion logging to AgentRunner). Only
  # logs when a resume was attempted, distinguishing a true resume from a
  # clean-start fallback so an Executor can see whether the agent rejoined its
  # prior thread or restarted cold.
  @doc false
  @spec log_resume_outcome(Issue.t(), map(), String.t() | nil) :: :ok
  def log_resume_outcome(_issue, _session, nil), do: :ok

  def log_resume_outcome(issue, session, resume_thread_id) when is_binary(resume_thread_id) do
    if session_resumed?(session) do
      Logger.info("Resumed prior agent session for #{Aiur.AgentRunner.issue_context(issue)} thread_id=#{Map.get(session, :thread_id)}")
    else
      Logger.info("Resume requested but degraded to a clean start for #{Aiur.AgentRunner.issue_context(issue)} requested_thread_id=#{resume_thread_id}")
    end

    :ok
  end

  # Persist the handle after a completed turn for a backend that only learns
  # its session id once a turn has run (the claude REPL reads it from the
  # transcript filename, unlike codex/headless which get a thread id at
  # `start_session`). `turn_handle_attrs/2` gates this to that case; the
  # resulting attrs still pass through `persist_session_handle/3`'s resumable +
  # local + thread-id gate.
  @doc false
  @spec maybe_persist_turn_handle(map(), map(), String.t(), worker_host()) :: :ok
  def maybe_persist_turn_handle(app_session, turn_session, identifier, worker_host) do
    case turn_handle_attrs(app_session, turn_session) do
      {:ok, attrs} -> persist_session_handle(attrs, identifier, worker_host)
      :skip -> :ok
    end
  end

  # The handle attrs to persist after a turn, or `:skip`. Persist only when the
  # turn's session id differs from the one the start session already carried:
  # codex/headless fix their thread id at `start_session` and a turn echoes it,
  # so they `:skip` (persisted once at start). The REPL learns its id per-turn
  # from the transcript filename — nil at a fresh start, and it can drift if the
  # CLI ever hands `--resume` a new id — so its live id is captured here, keeping
  # the handle pointed at the conversation the next restart should rejoin. Pure
  # so the gate is unit-testable without touching disk.
  @doc false
  @spec turn_handle_attrs(map(), map()) :: {:ok, map()} | :skip
  def turn_handle_attrs(app_session, turn_session) do
    turn_thread_id = Map.get(turn_session, :thread_id)
    backend = Map.get(app_session, :backend)

    if is_binary(turn_thread_id) and is_binary(backend) and turn_thread_id != Map.get(app_session, :thread_id) do
      {:ok, %{backend: backend, thread_id: turn_thread_id}}
    else
      :skip
    end
  end

  # Persist the live session handle so a future aiur restart can resume this
  # thread. Skips anything that can't be resumed later (non-resumable backend,
  # remote worker, no thread id) so we never leave a misleading handle.
  @doc false
  @spec persist_session_handle(map(), String.t(), worker_host()) :: :ok
  def persist_session_handle(session, identifier, worker_host) do
    case session_handle_to_save(session, worker_host) do
      {:ok, attrs} -> persist_handle_best_effort(identifier, attrs)
      :skip -> :ok
    end
  end

  # Best-effort persistence: `SessionHandle.save/3` (via `JsonStore.write!`)
  # raises on any I/O failure (disk full, read-only/permission-denied state
  # dir). A resume sidecar must never take down an agent run that already
  # started successfully, so swallow the failure — the only cost is that this
  # session won't resume on the next restart. Mirrors the rescue in
  # `Aiur.Events.SubscriptionStore.persist/1`.
  @doc false
  @spec persist_handle_best_effort(String.t(), map(), keyword()) :: :ok
  def persist_handle_best_effort(identifier, attrs, opts \\ []) do
    SessionHandle.save(identifier, attrs, opts)
    :ok
  rescue
    error ->
      Logger.warning("Could not persist session handle for #{identifier} (resume disabled for next restart): #{inspect(error)}")
      :ok
  end

  # The handle attrs to persist for `session`, or `:skip` when this session can
  # never be resumed later. Resume is local-only (the codex rollout is on this
  # host) and backend-gated (only codex today), and a session with no thread id
  # has nothing to rejoin.
  #
  # A session with no binary `:backend` also skips. The handle is durable state
  # keyed by backend, so writing the configured default here would stamp a
  # backend this session never established onto disk; `SessionHandle.load/2`
  # would then reject it as foreign and silently disable resume, moving the
  # failure a restart away from its cause (issue #1621).
  @doc false
  @spec session_handle_to_save(map(), worker_host()) :: {:ok, map()} | :skip
  def session_handle_to_save(%{thread_id: thread_id, backend: backend}, nil)
      when is_binary(thread_id) and is_binary(backend) do
    if CodingAgent.resumable?(backend) do
      {:ok, %{backend: backend, thread_id: thread_id}}
    else
      :skip
    end
  end

  def session_handle_to_save(_session, _worker_host), do: :skip
end
