defmodule Aiur.ExecutorWakeInbox.Recovery do
  @moduledoc false
  # Journal-fault handling for `Aiur.ExecutorWakeInbox`: quarantine a corrupt
  # tail at boot, and make flush/trim failures visible instead of silent.

  require Logger

  alias Aiur.Fs
  alias Aiur.Journal

  @flush_alert_threshold 3

  # A corrupt line stops the replay at the good prefix. Rather than refuse to
  # start forever (and loop the supervisor), keep the bad file as evidence and
  # restart on the prefix; any other replay error still stops the inbox.
  @spec replay_or_quarantine(Path.t(), (map() -> {:ok, map()} | {:error, term()}), function()) ::
          {:ok, [map()]} | {:error, term()}
  def replay_or_quarantine(path, validator, alert_fun) do
    case Journal.replay(path, validator) do
      {:ok, records, nil} -> {:ok, records}
      {:ok, records, {:corrupt, line, _reason} = corruption} -> quarantine(path, records, line, corruption, alert_fun)
      {:error, reason} -> {:error, reason}
    end
  end

  defp quarantine(path, good, line, corruption, alert_fun) do
    quarantined = "#{path}.corrupt-#{System.os_time(:second)}"
    bad_bytes = file_size(path)
    contents = Enum.map(good, &[Jason.encode!(&1), "\n"])

    with :ok <- File.rename(path, quarantined),
         :ok <- Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
      alert_fun.(
        "executor.wakes.journal_quarantined",
        "Executor wake journal was corrupt at line #{line}; #{length(good)} wakes kept, the rest of the #{bad_bytes}-byte file " <>
          "(unacknowledged wakes lost) moved to #{quarantined}. Run `aiur alerts`.",
        severity: "error"
      )

      {:ok, good}
    else
      {:error, reason} ->
        alert_fun.(
          "executor.wakes.journal_quarantined",
          "Executor wake journal is corrupt (#{inspect(corruption)}) and could not be quarantined: #{inspect(reason)}.",
          severity: "error"
        )

        {:error, corruption}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  @doc "Counts a consecutive flush failure, logging each and alerting once at the threshold."
  @spec flush_failed(map(), term()) :: map()
  def flush_failed(state, reason) do
    failures = state.flush_failures + 1
    Logger.warning("aiur_executor_wake_inbox phase=flush_failed consecutive=#{failures} reason=#{inspect(reason)}")

    if failures == @flush_alert_threshold do
      state.alert_fun.(
        "executor.wakes.flush_failing",
        "Executor wake journal flush failed #{failures} times in a row (#{inspect(reason)}); queued wakes are not durable yet.",
        severity: "error"
      )
    end

    %{state | flush_failures: failures}
  end

  # Logged every time, alerted once per process lifetime so a persistent fault
  # does not alert on every acknowledgement.
  @spec trim_failed(map(), term()) :: map()
  def trim_failed(state, reason) do
    Logger.warning("aiur_executor_wake_inbox phase=trim_failed reason=#{inspect(reason)}")

    if state.trim_alerted? do
      state
    else
      state.alert_fun.("executor.wakes.trim_failed", "Executor wake journal trim failed: #{inspect(reason)}.", severity: "warning")
      %{state | trim_alerted?: true}
    end
  end
end
