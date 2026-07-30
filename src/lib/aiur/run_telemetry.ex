defmodule Aiur.RunTelemetry do
  @moduledoc """
  Debug-gated facade for daemon-owned run telemetry.

  Callers use this module without coordinating with the telemetry supervisor.
  When debug mode is off, or while the writer is unavailable, recording is a
  fail-open no-op so diagnostics can never become an orchestration dependency.
  """

  alias Aiur.LogFile
  alias Aiur.RunTelemetry.Writer

  @filename "telemetry.ndjson"
  # Version 2 adds the dispatch-time complexity estimate to lifecycle records.
  @schema_version 2
  @boot_state_key {__MODULE__, :boot_state}

  @doc "Current durable telemetry schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc false
  @spec start_boot() :: :ok
  def start_boot do
    :persistent_term.put(@boot_state_key, new_boot_state())
    :ok
  end

  @doc "Delegates to `Aiur.Boot.run_id/0` so telemetry never reports a stale id after a test reboot."
  @spec boot_id() :: String.t()
  def boot_id, do: Aiur.Boot.run_id()

  @doc "Delegates to `Aiur.Boot.started_at/0`."
  @spec boot_started_at() :: DateTime.t()
  def boot_started_at, do: Aiur.Boot.started_at()

  @doc false
  @spec next_sequence() :: pos_integer()
  def next_sequence do
    :atomics.add_get(boot_state().sequence_counter, 1, 1)
  end

  @doc "Canonical telemetry stream beside the configured daemon log."
  @spec telemetry_file() :: Path.t()
  def telemetry_file do
    log_file =
      case Application.get_env(:aiur, :log_file) do
        path when is_binary(path) and path != "" -> path
        _other -> LogFile.default_log_file()
      end

    Path.join(Path.dirname(log_file), @filename)
  end

  @doc "Best-effort append of one telemetry record."
  @spec record(atom() | String.t(), map()) :: :ok
  def record(kind, attributes \\ %{}), do: record(kind, attributes, [])

  @doc false
  @spec record(atom() | String.t(), map(), keyword()) :: :ok
  def record(kind, attributes, opts)
      when (is_atom(kind) or is_binary(kind)) and is_map(attributes) and is_list(opts) do
    if LogFile.debug_enabled?() do
      writer = Keyword.get(opts, :writer, Writer)
      Writer.record(writer, kind, attributes, Keyword.delete(opts, :writer))
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  def record(_kind, _attributes, _opts), do: :ok

  @doc false
  @spec record_batch([{atom() | String.t(), map()}], keyword()) :: :ok
  def record_batch(records, opts \\ [])

  def record_batch(records, opts) when is_list(records) and is_list(opts) do
    if LogFile.debug_enabled?() do
      writer = Keyword.get(opts, :writer, Writer)
      Writer.record_batch(writer, records, Keyword.delete(opts, :writer))
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  def record_batch(_records, _opts), do: :ok

  defp boot_state do
    case :persistent_term.get(@boot_state_key, :unset) do
      :unset -> initialize_boot_state()
      state -> state
    end
  end

  defp initialize_boot_state do
    state = new_boot_state()
    :persistent_term.put(@boot_state_key, state)
    state
  end

  defp new_boot_state do
    %{sequence_counter: :atomics.new(1, signed: false)}
  end
end
