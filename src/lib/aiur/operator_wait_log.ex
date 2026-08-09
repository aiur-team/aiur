defmodule Aiur.OperatorWaitLog do
  @moduledoc """
  Records how long Executor messages sit between submission
  (`Aiur.AgentChat.send/3` accept) and provider-confirmed delivery. Appends one NDJSON line per
  delivered message to `<log-root>/metrics/operator_message_wait.ndjson`.

  The file survives `aiur --clear` (sits in a subdirectory; --clear
  only deletes top-level `aiur*.log`) and `aiur --test` (sandbox
  reset only touches GitHub state) so wait-time samples accumulate
  across runs for trend analysis.

  Line shape:

      {"at":"2026-05-26T01:18:26.000Z","identifier":"101","request_id":42,
       "wait_ms":51847,"text_bytes":48}

  Wait deltas use `System.system_time/1` so cross-run NDJSON entries
  share a wall-clock reference; monotonic time would not.
  """

  use GenServer
  require Logger

  alias Aiur.Metrics

  @table :aiur_operator_wait_pending
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
  Note an Executor message accepted into the queue. Called by the orchestrator
  before it notifies the worker, so a provider acknowledgement cannot outrun
  the queued timestamp.
  """
  @spec record_queued(integer(), String.t(), non_neg_integer()) :: :ok
  def record_queued(request_id, identifier, text_bytes)
      when is_integer(request_id) and is_binary(identifier) and is_integer(text_bytes) do
    if ets_ready?() do
      :ets.insert(
        @table,
        {{identifier, request_id}, System.system_time(:millisecond), text_bytes}
      )
    end

    :ok
  end

  @doc """
  Note a provider-confirmed Executor message and append the wait delta to
  the NDJSON file. Called only after the provider accepts a new turn or
  emits equivalent receipt evidence for an interactive session.

  Silently no-ops when no queued record exists (writer started after
  the message was enqueued, or this `request_id` came from a
  non-Executor queue item).
  """
  @spec record_delivered(integer(), String.t()) :: :ok
  def record_delivered(request_id, identifier)
      when is_integer(request_id) and is_binary(identifier) do
    if ets_ready?() do
      case :ets.take(@table, {identifier, request_id}) do
        [{_key, queued_at, bytes}] ->
          wait_ms = System.system_time(:millisecond) - queued_at
          append_line(identifier, request_id, wait_ms, bytes)

        [] ->
          :ok
      end
    end

    :ok
  end

  @doc """
  Absolute path of the NDJSON metrics file. Resolution order:

    1. `Application.get_env(:aiur, :operator_wait_metrics_path)` —
       tests set this to a tmp path.
    2. `<dirname(:log_file)>/metrics/operator_message_wait.ndjson` —
       sits next to `aiur.log` under whatever `--logs-root` resolved
       to.
  """
  @spec metrics_file() :: Path.t()
  def metrics_file, do: Metrics.file(:operator_wait_metrics_path, @metrics_filename)

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
      Logger.error("operator_wait_log write failed identifier=#{identifier} request_id=#{request_id} wait_ms=#{wait_ms} error=#{inspect(error)}")
  end
end
