defmodule Aiur.BuildOrder.History.LabelBackfill.Checkpoint do
  @moduledoc false
  alias Aiur.{Fs, JSONSafe}

  @keys ~w(v repository run window items ensured state per_hour epic_labels started_by started_at expect hold_until stop_reason ticket kind label slug_or_epic status attempts at seen_at reason last_error projection)a
  @atoms ~w(idle running paused stopped finished feature epic pending written written_unmarked already_present skipped failed changed unconfirmed open gone left auth forbidden unsupported checkpoint_write_failed)a
  @dates ~w(started_at hold_until at seen_at)a
  @spec empty(String.t()) :: map()
  def empty(repository), do: %{v: 1, repository: repository, run: %{state: :idle, per_hour: 60, epic_labels: false, hold_until: nil, stop_reason: nil}, window: [], items: %{}, ensured: []}

  @spec load(Path.t() | nil, String.t()) :: {:ok, map()} | {:error, atom()}
  def load(nil, _repository), do: {:error, :state_dir_unavailable}

  def load(path, repository) do
    case File.lstat(path) do
      {:error, :enoent} -> if File.exists?(path <> ".corrupt"), do: {:error, :checkpoint_corrupt}, else: {:ok, empty(repository)}
      {:ok, %{type: :regular, size: size}} when size <= 16_777_216 -> read(path, repository)
      {:ok, %{type: :regular}} -> corrupt(path)
      _ -> {:error, :unsafe_checkpoint}
    end
  end

  defp read(path, repository) do
    with {:ok, bytes} <- File.read(path), {:ok, json} <- Jason.decode(bytes) do
      decode(json, path, repository)
    else
      _ -> corrupt(path)
    end
  end

  defp decode(%{"v" => v}, _path, _repo) when v != 1, do: {:error, :checkpoint_version}
  defp decode(%{"repository" => other}, _path, repo) when other != repo, do: {:error, :repository_mismatch}

  defp decode(json, path, repository) do
    data = from_json(json)
    if valid?(data, repository), do: {:ok, data}, else: corrupt(path)
  rescue
    _ -> corrupt(path)
  end

  defp from_json(json) do
    Map.new(json, fn {key, value} ->
      atom = Enum.find(@keys, &(Atom.to_string(&1) == key)) || raise ArgumentError
      {atom, value(atom, value)}
    end)
  end

  defp value(:items, items), do: Map.new(items, fn {id, item} -> {id, from_json(item)} end)
  defp value(:run, run), do: from_json(run)
  defp value(:window, times), do: Enum.map(times, &date/1)
  defp value(key, nil) when key in @dates, do: nil
  defp value(key, time) when key in @dates, do: date(time)
  defp value(key, nil) when key in [:stop_reason, :reason, :projection], do: nil
  defp value(key, text) when key in [:state, :kind, :status, :stop_reason, :reason, :projection], do: Enum.find(@atoms, &(Atom.to_string(&1) == text)) || raise(ArgumentError)
  defp value(_key, value), do: value

  defp date(text) do
    {:ok, at, _} = DateTime.from_iso8601(text)
    at
  end

  defp valid?(%{v: 1, repository: repo, run: run, window: window, items: items, ensured: ensured}, repo) do
    Enum.all?([
      valid_run?(run),
      is_binary(repo),
      repo != "",
      is_list(window),
      is_list(ensured),
      Enum.all?(ensured, &is_binary/1),
      Enum.all?(items, fn {id, item} -> valid_item?(id, item) end)
    ])
  end

  defp valid?(_, _), do: false

  defp valid_run?(run) do
    Enum.all?([
      run.state in [:idle, :running, :paused, :stopped, :finished],
      is_integer(run.per_hour),
      run.per_hour > 0,
      is_boolean(run.epic_labels),
      date?(run.hold_until),
      Map.has_key?(run, :stop_reason)
    ])
  end

  defp valid_item?(id, item) do
    Enum.all?([
      is_binary(id),
      item.kind in [:feature, :epic],
      is_integer(item.ticket),
      item.ticket > 0,
      is_binary(item.label),
      is_binary(item.slug_or_epic),
      is_integer(item.attempts),
      item.attempts >= 0,
      item.status in [:pending, :written, :written_unmarked, :already_present, :skipped, :failed],
      date?(item.at),
      date?(item.seen_at)
    ])
  end

  defp date?(nil), do: true
  defp date?(%DateTime{}), do: true
  defp date?(_), do: false

  defp corrupt(path) do
    # The durable tombstone prevents a second boot forgetting the reserved window.
    case File.rename(path, path <> ".corrupt") do
      :ok -> {:error, :checkpoint_corrupt}
      _ -> {:error, :checkpoint_unavailable}
    end
  end

  @spec save(Path.t() | nil, map(), keyword()) :: :ok | {:error, term()}
  def save(nil, _data, _opts), do: {:error, :state_dir_unavailable}

  def save(path, data, opts) do
    writer = Keyword.get(opts, :writer, &Fs.atomic_write/3)
    first? = not File.exists?(path)
    sync = Keyword.get(opts, :sync, &Fs.sync_filesystem/0)

    with :ok <- safe_path(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- writer.(path, Jason.encode!(JSONSafe.normalize(data)), fsync: true, mode: 0o600),
         do: if(first?, do: sync.(), else: :ok)
  end

  defp safe_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      _ -> {:error, :unsafe_checkpoint}
    end
  end
end
