defmodule Aiur.OperatorWaitLog do
  @moduledoc """
  Persistent metrics log for operator-message wait times — how long a
  user message sits in the queue between submission (the moment
  `AgentChat.send` accepts it) and delivery (the moment
  `agent_runner.run_queue_item_turn` starts a codex turn with it).

  Why this exists: the bridge intentionally uses the `:checkpoint`
  delivery policy (no codex turn-boundary interrupt) — see the comment
  in `Aiur.Opencode.ChatCompletions.send_operator/3`. The cost is that
  the user may wait the full length of the active turn before the agent
  sees their message. This log lets us measure that wait over time so
  we know whether the current design is acceptable UX or needs to be
  revisited.

  Storage: one NDJSON line per delivered operator message at
  `<log-root>/metrics/operator_message_wait.ndjson`. Survives
  `aiur --clear` (the find in `scripts/aiur` only deletes top-level
  `aiur*.log` files in the log dir) and `aiur --test` (the sandbox
  reset only touches GitHub state).

  Line shape:

      {"at":"2026-05-26T01:18:26.000Z","identifier":"101","request_id":42,
       "wait_ms":51847,"text_bytes":48}

  Note on monotonicity: wait_ms uses `System.system_time(:millisecond)`
  deltas, not `System.monotonic_time`. Wall-clock skew during a single
  agent run is negligible; cross-run comparison is the value here.
  """

  use GenServer
  require Logger

  @table :aiur_operator_wait_pending
  @metrics_subdir "metrics"
  @metrics_filename "operator_message_wait.ndjson"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Record that an operator message was accepted into the queue. Called
  from `Aiur.AgentChat.send/3` after `Orchestrator.send_operator_message`
  returns `{:ok, request_id}`.
  """
  @spec record_queued(integer(), String.t(), non_neg_integer()) :: :ok
  def record_queued(request_id, identifier, text_bytes)
      when is_integer(request_id) and is_binary(identifier) and is_integer(text_bytes) do
    if ets_ready?() do
      :ets.insert(@table, {request_id, identifier, System.system_time(:millisecond), text_bytes})
    end

    :ok
  end

  @doc """
  Record that an operator message was delivered to the agent. Computes
  the wait delta vs. the recorded queued timestamp and appends one
  NDJSON line to the metrics file. Called from
  `Aiur.AgentRunner.run_queue_item_turn/6` for items with
  `category: :operator_message`.

  Silently no-ops when no queued record exists — happens for messages
  that were enqueued before the writer started (e.g., across a restart)
  and for non-operator queue items that happen to share an integer id.
  """
  @spec record_delivered(integer(), String.t()) :: :ok
  def record_delivered(request_id, identifier)
      when is_integer(request_id) and is_binary(identifier) do
    if ets_ready?() do
      case :ets.take(@table, request_id) do
        [{^request_id, ^identifier, queued_at, bytes}] ->
          wait_ms = System.system_time(:millisecond) - queued_at
          append_line(identifier, request_id, wait_ms, bytes)

        _ ->
          :ok
      end
    end

    :ok
  end

  @doc """
  Absolute path of the metrics file. Resolution order:

    1. `Application.get_env(:aiur, :operator_wait_metrics_path)` — tests
       set this to a tmp path.
    2. `<dirname(:log_file)>/metrics/operator_message_wait.ndjson` —
       sits next to `aiur.log` under whatever `--logs-root` resolved to.
  """
  @spec metrics_file() :: Path.t()
  def metrics_file do
    case Application.get_env(:aiur, :operator_wait_metrics_path) do
      path when is_binary(path) ->
        path

      _ ->
        log_file = Application.get_env(:aiur, :log_file, Aiur.LogFile.default_log_file())

        log_file
        |> Path.dirname()
        |> Path.join(@metrics_subdir)
        |> Path.join(@metrics_filename)
    end
  end

  defp ets_ready? do
    :ets.whereis(@table) != :undefined
  end

  defp append_line(identifier, request_id, wait_ms, bytes) do
    payload = %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      identifier: identifier,
      request_id: request_id,
      wait_ms: wait_ms,
      text_bytes: bytes
    }

    path = metrics_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload) <> "\n", [:append])
  rescue
    error ->
      Logger.warning("operator_wait_log write failed: #{inspect(error)}")
  end
end
