defmodule Aiur.BuildOrder.Estimates.Store do
  @moduledoc false
  require Logger
  alias Aiur.BuildOrder.{Estimates, ProviderHealth}
  @max_bytes 1_048_576

  @spec healthy(non_neg_integer()) :: ProviderHealth.t()
  def healthy(generation), do: %ProviderHealth{state: :healthy, complete?: true, generation: generation, observed_at: DateTime.utc_now()}

  @spec load(keyword()) :: map()
  def load(opts) do
    state = %{tickets: %{}, generation: 0, repository: nil, path: nil, writer: Keyword.get(opts, :writer, &Aiur.Fs.atomic_write/3), health: %ProviderHealth{failure: :state_dir_unavailable}}

    with {:ok, dir} <- directory(opts),
         :ok <- File.mkdir_p(dir),
         {:ok, %{type: :directory}} <- File.lstat(dir),
         repo when is_binary(repo) and repo != "" <- Keyword.get_lazy(opts, :repository, &Aiur.Tracker.project_identity/0) do
      state = %{state | repository: repo, path: Path.join(dir, "estimates.json")}

      case read(state.path, repo) do
        {:ok, tickets, generation} -> %{state | tickets: tickets, generation: generation, health: healthy(generation)}
        {:error, reason} -> %{state | health: %ProviderHealth{failure: reason}}
      end
    else
      _ -> state
    end
  rescue
    _ -> %{tickets: %{}, generation: 0, repository: nil, path: nil, writer: &Aiur.Fs.atomic_write/3, health: %ProviderHealth{failure: :state_dir_unavailable}}
  catch
    _, _ -> %{tickets: %{}, generation: 0, repository: nil, path: nil, writer: &Aiur.Fs.atomic_write/3, health: %ProviderHealth{failure: :state_dir_unavailable}}
  end

  defp directory(opts) do
    case Keyword.fetch(opts, :state_dir) do
      {:ok, dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      :error -> Aiur.Config.Paths.build_estimates_state_dir()
      _ -> {:error, :state_dir_unavailable}
    end
  end

  defp read(path, repo) do
    case File.lstat(path) do
      {:error, :enoent} -> if Path.wildcard(path <> ".corrupt-*") == [], do: {:ok, %{}, 0}, else: {:error, :estimates_corrupt}
      {:ok, %{type: :regular, size: size}} when size <= @max_bytes -> decode(path, repo)
      _ -> {:error, :estimates_unsafe_path}
    end
  end

  defp decode(path, repo) do
    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes) do
      load_data(data, path, repo)
    else
      _ -> corrupt(path)
    end
  end

  defp load_data(%{"version" => v}, _path, _repo) when is_integer(v) and v > 1, do: {:error, :version_unsupported}
  defp load_data(%{"version" => 1, "repository" => other}, _path, repo) when other != repo, do: {:error, :repository_mismatch}

  defp load_data(%{"version" => 1, "repository" => _, "generation" => g, "tickets" => tickets}, path, _repo)
       when is_integer(g) and g >= 0 and is_map(tickets) do
    case decode_tickets(tickets) do
      {:ok, decoded} -> {:ok, decoded, g}
      :error -> corrupt(path)
    end
  end

  defp load_data(_, path, _), do: corrupt(path)

  defp corrupt(path) do
    case Aiur.Fs.quarantine(path) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("estimate store quarantine failed path=#{path} reason=#{inspect(reason)}")
    end

    {:error, :estimates_corrupt}
  end

  defp decode_tickets(tickets) do
    Enum.reduce_while(tickets, {:ok, %{}}, fn {key, ticket}, {:ok, acc} ->
      with {id, ""} when id > 0 <- Integer.parse(key),
           true <- Integer.to_string(id) == key,
           {:ok, decoded} <- decode_ticket(ticket) do
        {:cont, {:ok, Map.put(acc, id, decoded)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp decode_ticket(%{"override" => override, "journal" => journal}) when is_list(journal) and length(journal) <= 20 do
    with {:ok, record} <- decode_record(override),
         {:ok, entries} <- decode_entries(journal) do
      {:ok, %{override: record, journal: entries}}
    end
  end

  defp decode_ticket(_), do: :error

  defp decode_record(nil), do: {:ok, nil}

  defp decode_record(%{"hours" => h, "reason" => r, "by" => b, "at" => at}) when is_binary(at) do
    with {:ok, r} <- Estimates.validate(1, h, r, b),
         {:ok, datetime, 0} <- DateTime.from_iso8601(at) do
      {:ok, %{hours: h, reason: r, by: b, at: datetime}}
    else
      _ -> :error
    end
  end

  defp decode_record(_), do: :error

  defp decode_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case decode_entry(entry) do
        {:ok, decoded} -> {:cont, {:ok, acc ++ [decoded]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp decode_entry(%{"op" => "set"} = entry) do
    with {:ok, record} <- decode_record(entry), do: {:ok, Map.put(record, :op, :set)}
  end

  defp decode_entry(%{"op" => "clear", "hours" => nil} = entry) do
    with {:ok, record} <- decode_record(Map.put(entry, "hours", 1)), do: {:ok, %{record | hours: nil} |> Map.put(:op, :clear)}
  end

  defp decode_entry(_), do: :error

  @spec write(map()) :: :ok | {:error, term()}
  def write(state) do
    with {:ok, %{type: :directory}} <- File.lstat(Path.dirname(state.path)),
         :ok <- safe_destination(state.path),
         {:ok, json} <- Jason.encode(%{version: 1, repository: state.repository, generation: state.generation, tickets: state.tickets}),
         true <- byte_size(json) <= @max_bytes do
      state.writer.(state.path, json, mode: 0o600, fsync: true)
    else
      _ -> {:error, :write_failed}
    end
  rescue
    _ -> {:error, :write_failed}
  end

  defp safe_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular, size: size}} when size <= @max_bytes -> :ok
      _ -> {:error, :estimates_unsafe_path}
    end
  end
end
