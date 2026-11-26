defmodule Aiur.Experiments.WindowEvents.Local do
  @moduledoc false
  alias Aiur.Experiments.Sources.Common
  alias Aiur.Experiments.WindowEvents
  alias Aiur.Experiments.WindowEvents.{Alerts, Telemetry}

  @spec collect(keyword()) :: {[map()], [String.t()]}
  def collect(opts) do
    {records, missing} = Keyword.get(opts, :records_fun, &Telemetry.read/1).(opts)
    records = Enum.filter(records, &(is_map(&1) and Common.timestamp(&1["timestamp"]))) |> Enum.sort_by(&{DateTime.to_unix(Common.timestamp(&1["timestamp"]), :microsecond), &1["record_id"]})
    missing = if starts_late?(records, opts[:range_start]), do: ["telemetry" | missing], else: missing
    contexts = Enum.filter(records, &(&1["kind"] == "run_context"))
    samples = Enum.filter(records, &(is_integer(get_in(&1, ["attributes", "fleet_agents_max"])) and is_integer(get_in(&1, ["attributes", "fleet_agents_effective"]))))
    {alerts, alerts_missing} = Alerts.collect(opts)

    absent =
      for {field, kind} <- [{"aiur_vsn", "version_change"}, {"config_hash", "config_change"}],
          not Enum.any?(contexts, &(is_binary(&1["attributes"][field]) and &1["attributes"][field] != "unknown")),
          do: kind

    absent = if samples == [], do: ["capacity_change", "global_pause" | absent], else: absent
    events = outages(records) ++ transitions(contexts, "aiur_vsn", "version_change") ++ transitions(contexts, "config_hash", "config_change") ++ capacity(samples) ++ alerts
    {events, Enum.uniq(missing ++ absent ++ alerts_missing)}
  end

  defp starts_late?([], _start), do: true
  defp starts_late?(_records, nil), do: false
  defp starts_late?(records, start), do: DateTime.compare(Common.timestamp(hd(records)["timestamp"]), Common.timestamp(start)) == :gt

  @spec outages([map()]) :: [map()]
  def outages(records) do
    records
    |> Enum.filter(&(&1["kind"] == "restart" and get_in(&1, ["attributes", "event"]) == "daemon_restart"))
    |> Enum.map(fn row -> Map.put(row, "timestamp", get_in(row, ["attributes", "daemon_started_at"]) || row["timestamp"]) end)
    |> Enum.uniq_by(& &1["boot_id"])
    |> Enum.sort_by(& &1["timestamp"])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [first, last] ->
      if seconds(first, last) > 600 do
        [
          WindowEvents.event("outage", "local", last["boot_id"], first["timestamp"],
            from: first["timestamp"],
            to: last["timestamp"],
            attrs: %{"previous_boot" => first["boot_id"], "boot" => last["boot_id"]}
          )
        ]
      else
        []
      end
    end)
  end

  defp transitions(records, field, kind) do
    records
    |> Enum.filter(&(is_binary(get_in(&1, ["attributes", field])) and get_in(&1, ["attributes", field]) != "unknown"))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [first, last] ->
      before = first["attributes"][field]
      after_value = last["attributes"][field]
      attrs = %{"before" => before, "after" => after_value}
      attrs = if field == "config_hash", do: Map.put(attrs, "changed_keys", changed_keys(first, last)), else: attrs
      if before == after_value, do: [], else: [WindowEvents.event(kind, "local", last["boot_id"] <> ":" <> last["timestamp"], last["timestamp"], attrs: attrs)]
    end)
  end

  defp changed_keys(first, last) do
    before = first["attributes"]["config_section_hashes"] || %{}
    after_value = last["attributes"]["config_section_hashes"] || %{}
    (Map.keys(before) ++ Map.keys(after_value)) |> Enum.uniq() |> Enum.filter(&(before[&1] != after_value[&1])) |> Enum.sort()
  end

  @spec capacity([map()]) :: [map()]
  def capacity([]), do: []

  def capacity(samples) do
    groups = Enum.chunk_by(samples, &caps/1)

    groups
    |> Enum.with_index()
    |> Enum.reduce({[], caps(hd(samples))}, fn {group, index}, {events, stable} ->
      first = hd(group)
      next = Enum.at(groups, index + 1)
      last = if next, do: hd(next), else: List.last(group)
      span = [from: first["timestamp"], to: if(next, do: last["timestamp"]), attrs: %{"max" => elem(caps(first), 0), "effective" => elem(caps(first), 1)}]
      key = first["boot_id"] <> ":" <> first["timestamp"]
      sustained? = seconds(first, last) >= 900
      change = if caps(first) != stable and sustained?, do: [WindowEvents.event("capacity_change", "local", key, first["timestamp"], span)], else: []
      pause = if elem(caps(first), 1) == 0, do: [WindowEvents.event("global_pause", "local", key, first["timestamp"], span)], else: []
      {events ++ change ++ pause, if(sustained? or index == 0, do: caps(first), else: stable)}
    end)
    |> elem(0)
  end

  defp caps(row), do: {row["attributes"]["fleet_agents_max"], row["attributes"]["fleet_agents_effective"]}
  defp seconds(first, last), do: DateTime.diff(Common.timestamp(last["timestamp"]), Common.timestamp(first["timestamp"]))
end
