defmodule Aiur.BuildOrder.Features.Persistence do
  @moduledoc false
  require Logger

  alias Aiur.{Alerts, Config, Fs}
  alias Aiur.BuildOrder.Features.Journal
  alias Aiur.BuildOrder.ProviderHealth
  alias Aiur.Journal, as: AppendJournal

  @spec boot(keyword()) :: map()
  def boot(opts) do
    state = options(opts)

    with {:ok, dir} <- state_dir(opts),
         path = Path.join(dir, "features.ndjson"),
         :ok <- AppendJournal.prepare(dir, path, state.sync_fun) do
      replay(%{state | path: path})
    else
      {:error, reason} -> fail(state, boot_failure(reason))
    end
  end

  defp options(opts) do
    %{
      path: nil,
      projection: Journal.empty(),
      writable?: true,
      bytes: 0,
      health: nil,
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      append_fun: Keyword.get(opts, :append_fun, &AppendJournal.append/2),
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0),
      alert_fun: Keyword.get(opts, :alert_fun, &Alerts.emit_custom/3),
      general_epics: epic_reader(Keyword.get(opts, :general_epics, &configured_epics/0)),
      max_record_bytes: Keyword.get(opts, :max_record_bytes, 1_048_576),
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 16_777_216)
    }
  end

  defp epic_reader(fun) when is_function(fun, 0), do: fun
  defp epic_reader(epics) when is_list(epics), do: fn -> {:ok, epics} end
  defp epic_reader(_), do: fn -> {:error, :invalid} end

  defp configured_epics do
    with {:ok, settings} <- Config.settings(), do: {:ok, settings.build_order.general_epics}
  end

  defp state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> Config.Paths.build_features_state_dir()
    end
  end

  defp replay(state) do
    limits = [max_record_bytes: state.max_record_bytes, max_file_bytes: state.max_file_bytes]

    case AppendJournal.replay(state.path, &Journal.validate/1, limits) do
      {:ok, records, nil} -> fold_records(records, state)
      {:ok, _prefix, {:corrupt, _, reason}} -> fail(state, corruption_failure(reason))
      {:error, reason} -> fail(state, replay_failure(reason))
    end
  end

  defp fold_records(records, state) do
    result =
      Enum.reduce_while(records, {:ok, Journal.empty()}, fn record, {:ok, projection} ->
        case Journal.fold(projection, record) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, projection} -> replayed(records, projection, state)
      {:error, _reason} -> fail(state, :features_corrupt)
    end
  end

  defp replayed(records, projection, state) do
    observed =
      case List.last(records) do
        nil -> state.clock.()
        record -> record.recorded_at
      end

    case File.stat(state.path) do
      {:ok, stat} -> %{state | projection: projection, bytes: stat.size, health: healthy(projection, observed)}
      {:error, _reason} -> fail(state, :state_dir_unavailable)
    end
  end

  @spec append(map(), map(), map()) :: {:ok, map()} | {:error, term(), map()}
  def append(record, projection, state) do
    encoded = Journal.encode(record)
    bytes = byte_size(Jason.encode!(encoded)) + 1

    cond do
      bytes > state.max_record_bytes -> {:error, :record_too_large, state}
      state.bytes + bytes > state.max_file_bytes -> {:error, :features_too_large, state}
      true -> append_record(encoded, record, projection, bytes, state)
    end
  end

  defp append_record(encoded, record, projection, bytes, state) do
    case state.append_fun.(state.path, encoded) do
      :ok -> {:ok, %{state | projection: projection, bytes: state.bytes + bytes, health: healthy(projection, record.recorded_at)}}
      {:error, reason} -> {:error, {:journal_append_failed, reason}, fail(state, :journal_append_failed)}
    end
  end

  defp healthy(projection, observed) do
    ProviderHealth.new(projection.seq + 1, :healthy, true, observed_at: observed, last_success_at: observed)
  end

  defp boot_failure({:symlink_rejected, _}), do: :unsafe_path
  defp boot_failure(_), do: :state_dir_unavailable
  defp replay_failure({:symlink_rejected, _}), do: :unsafe_path
  defp replay_failure(:recovery_file_too_large), do: :features_too_large
  defp replay_failure(_), do: :state_dir_unavailable
  defp corruption_failure(:record_too_large), do: :features_too_large
  defp corruption_failure(:version_unsupported), do: :version_unsupported
  defp corruption_failure(_), do: :features_corrupt

  defp fail(state, failure) do
    health = failed_health(state, failure)
    alert(state, failure)
    %{state | writable?: false, health: health}
  end

  defp failed_health(%{health: %ProviderHealth{} = health}, :journal_append_failed) do
    %{health | state: :stale, failure: :journal_append_failed}
  end

  defp failed_health(state, failure) do
    status = if failure in [:features_corrupt, :features_too_large], do: :structurally_invalid, else: :unavailable
    ProviderHealth.new(:unknown, status, false, observed_at: state.clock.(), failure: failure)
  end

  defp alert(state, failure) do
    topic = if failure == :features_corrupt, do: "build_features.corrupted", else: "build_features.unavailable"
    message = "Feature registry unavailable: #{failure}; journal #{inspect(state.path)} requires operator recovery."
    state.alert_fun.(topic, message, needs_attention: true, severity: "warning", reason: message)
  rescue
    error -> Logger.warning("build_features alert failed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("build_features alert failed: #{inspect({kind, reason})}")
  end

  # ponytail: no compaction until a production census finds the journal above 4 MB.
end
