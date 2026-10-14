defmodule Aiur.Experiments.WindowEvents do
  @moduledoc "Deterministic confounder evidence, frozen as immutable NDJSON snapshots."
  alias Aiur.Experiments.{Paths, Persistence, Reader}
  alias Aiur.Experiments.Sources.Common
  alias Aiur.Experiments.WindowEvents.{GitHub, Limits, Local}

  @spec collect(map(), keyword()) :: map()
  def collect(experiment, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    windows = windows(experiment, now)
    starts = Enum.map(windows, & &1.start)
    stops = Enum.map(windows, & &1.end)
    range = %{start: starts |> Enum.min(DateTime) |> DateTime.add(-86_400) |> DateTime.to_iso8601(), end: stops |> Enum.max(DateTime) |> DateTime.to_iso8601()}
    scope_hash = request_hash(experiment)
    sources = sources(experiment)
    {local, local_missing} = Local.collect(opts |> Keyword.put(:range_start, range.start) |> Keyword.put(:range_end, range.end))
    {github, github_missing} = GitHub.collect(Keyword.get(opts, :repo, Paths.repo()), sources, range, opts)

    events =
      (local ++ github)
      |> Enum.sort_by(&{&1["at"], &1["event_id"], canonical(&1)})
      |> Enum.uniq_by(& &1["event_id"])
      |> Enum.flat_map(fn event ->
        case classify(event, windows) do
          nil -> []
          window -> [Map.put(event, "window", window)]
        end
      end)

    {events, capped_sources} = Limits.events(events)

    snapshot = %{
      "schema_version" => 1,
      "request_hash" => scope_hash,
      "events" => events,
      "collected_at" => DateTime.to_iso8601(now),
      "range" => Map.new(range, fn {key, value} -> {to_string(key), value} end),
      "incomplete_sources" => Enum.uniq(local_missing ++ github_missing ++ capped_sources) |> Enum.sort()
    }

    Map.put(snapshot, "snapshot_hash", snapshot_hash(snapshot))
  end

  @spec request_hash(map()) :: String.t()
  def request_hash(experiment), do: hash(%{"windows" => experiment["windows"], "sources" => sources(experiment), "repo" => Paths.repo()})

  @spec sources(map()) :: map()
  def sources(experiment) do
    Map.merge(%{"base_branch" => Aiur.Config.base_branch(), "required_workflows" => [], "incident_labels" => ["incident", "outage"]}, experiment["confounder_sources"] || %{})
  end

  @spec snapshot(map()) :: {:ok, map()} | {:error, term()}
  def snapshot(experiment) do
    with {:ok, names} <- File.ls(Paths.experiment(experiment["id"])) do
      names
      |> Enum.filter(&Regex.match?(~r/^events-\d+\.ndjson$/, &1))
      |> Enum.sort_by(&number/1, :desc)
      |> Enum.reduce_while({:error, :not_found}, &find_snapshot(&1, &2, experiment))
    end
  end

  defp find_snapshot(name, _acc, experiment) do
    case read_snapshot(Paths.file(experiment["id"], name)) do
      {:ok, snapshot} -> matching_snapshot(snapshot, experiment)
      error -> {:halt, error}
    end
  end

  defp matching_snapshot(snapshot, experiment) do
    if snapshot["request_hash"] == request_hash(experiment), do: {:halt, {:ok, snapshot}}, else: {:cont, {:error, :not_found}}
  end

  @spec freeze(String.t(), map(), boolean()) :: {:ok, map()} | {:error, term()}
  def freeze(id, data, refresh?) do
    with :ok <- Persistence.writable(id), {:ok, spec, false} <- Reader.spec(id), true <- data["request_hash"] == request_hash(spec) do
      case snapshot(spec) do
        {:ok, old} when not refresh? -> {:ok, old}
        {:error, reason} when reason != :not_found -> {:error, reason}
        _otherwise -> write_snapshot(id, data)
      end
    else
      false -> {:error, :experiment_changed}
      error -> error
    end
  end

  defp write_snapshot(id, data) do
    with {:ok, names} <- File.ls(Paths.experiment(id)) do
      snapshots = Enum.filter(names, &Regex.match?(~r/^events-\d+\.ndjson$/, &1))
      if Limits.snapshots_available?(length(snapshots)), do: persist_snapshot(id, data, snapshots), else: {:error, :events_snapshot_limit}
    end
  end

  defp persist_snapshot(id, data, names) do
    n = names |> Enum.map(&number/1) |> Enum.max(fn -> 0 end) |> Kernel.+(1)
    data = Map.put(data, "snapshot", "events-#{n}.ndjson")
    bytes = Enum.map([Map.delete(data, "events") | data["events"]], &[canonical(&1), "\n"])

    if :erlang.iolist_size(bytes) <= Limits.max_bytes() do
      with :ok <- Aiur.Fs.atomic_write(Paths.file(id, data["snapshot"]), bytes, fsync: true, mode: 0o600), do: {:ok, data}
    else
      {:error, :events_snapshot_too_large}
    end
  end

  defp read_snapshot(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         true <- size <= Limits.max_bytes(),
         {:ok, body} <- File.read(path) do
      body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode/1) |> decode_snapshot()
    else
      false -> {:error, :events_snapshot_too_large}
      error -> error
    end
  end

  defp decode_snapshot([{:ok, %{"schema_version" => 1, "snapshot_hash" => _hash} = header} | rows]) do
    events = for {:ok, row} <- rows, is_map(row), do: row
    data = Map.put(header, "events", events)
    payload = Map.drop(data, ~w(snapshot snapshot_hash))
    if length(events) == length(rows) and snapshot_hash(payload) == data["snapshot_hash"], do: {:ok, data}, else: {:error, :invalid_events_snapshot}
  end

  defp decode_snapshot(_invalid), do: {:error, :invalid_events_snapshot}

  defp number(name), do: name |> String.trim_leading("events-") |> String.trim_trailing(".ndjson") |> String.to_integer()

  defp windows(experiment, now) do
    Enum.map(experiment["windows"], fn {name, window} ->
      finish = Common.timestamp(window["end"]) || now
      finish = if DateTime.compare(finish, now) == :gt, do: now, else: finish
      %{name: name, start: Common.timestamp(window["start"]), end: finish}
    end)
    |> Enum.sort_by(& &1.start, DateTime)
  end

  defp classify(event, windows) do
    first = Common.timestamp(event["from"] || event["at"])
    last = Common.timestamp(event["to"])
    span? = not is_nil(event["from"])
    actual = Enum.find(windows, &overlaps?(first, last, span?, &1.start, &1.end))
    margin = Enum.any?(windows, &overlaps?(first, last, span?, DateTime.add(&1.start, -86_400), &1.start))
    between = length(windows) > 1 and overlaps?(first, last, span?, hd(windows).end, List.last(windows).start)

    cond do
      actual -> actual.name
      between -> "between"
      margin -> "margin"
      true -> nil
    end
  end

  defp overlaps?(nil, _last, _span?, _start, _stop), do: false
  defp overlaps?(first, last, true, start, stop), do: DateTime.compare(first, stop) == :lt and (is_nil(last) or DateTime.compare(last, start) == :gt)
  defp overlaps?(first, _last, false, start, stop), do: DateTime.compare(first, start) != :lt and DateTime.compare(first, stop) == :lt

  @spec event(String.t(), String.t(), term(), String.t(), keyword()) :: map()
  def event(kind, source, key, at, opts \\ []) do
    %{
      "event_id" => "evt:#{kind}:#{source}:#{key}",
      "kind" => kind,
      "source" => source,
      "at" => at,
      "from" => opts[:from],
      "to" => opts[:to],
      "ref" => opts[:ref],
      "title" => String.slice(opts[:title] || "", 0, 200),
      "attrs" => opts[:attrs] || %{}
    }
  end

  @spec encoded_size(term()) :: non_neg_integer()
  def encoded_size(value), do: :erlang.iolist_size(canonical(value))

  @spec hash(term()) :: String.t()
  def hash(value), do: :crypto.hash(:sha256, canonical(value)) |> Base.encode16(case: :lower)

  defp snapshot_hash(data) do
    header = Map.drop(data, ~w(events snapshot snapshot_hash collected_at))
    lines = Enum.map([header | data["events"]], &[canonical(&1), "\n"])
    :crypto.hash(:sha256, lines) |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    entries = value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, item} -> [Jason.encode!(key), ":", canonical(item)] end)
    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical(value) when is_list(value), do: ["[", Enum.intersperse(Enum.map(value, &canonical/1), ","), "]"]
  defp canonical(value), do: Jason.encode!(value)
end
