defmodule Aiur.Experiments.WindowEvents.Alerts do
  @moduledoc false
  alias Aiur.Experiments.Sources.Common
  alias Aiur.Experiments.WindowEvents
  alias Aiur.Jsonl

  @max_bytes 8 * 1_024 * 1_024
  @max_records 5_000
  @max_line 256 * 1_024
  @chunk 64 * 1_024

  @spec collect(keyword()) :: {[map()], [String.t()]}
  def collect(opts) do
    paths = Keyword.get_lazy(opts, :alert_files, fn -> Aiur.AlertLedger.paths() end)
    state = %{rows: [], count: 0, bytes: 0, missing: false, opts: opts, max_bytes: Keyword.get(opts, :alert_max_bytes, @max_bytes), max_records: Keyword.get(opts, :alert_max_records, @max_records)}
    state = Enum.reduce(paths, state, &read_file/2)
    {Enum.reverse(state.rows), if(state.missing, do: ["alerts"], else: [])}
  end

  defp read_file(path, state) do
    remaining = state.max_bytes - state.bytes

    if remaining <= 0 or state.count >= state.max_records do
      %{state | missing: true}
    else
      read_bounded(path, state, remaining)
    end
  end

  defp read_bounded(path, state, remaining) when is_binary(path) and is_integer(remaining) and remaining > 0 do
    chunk_size = min(@chunk, remaining)
    before = state.bytes

    {state, buffer, skipping?} =
      path
      |> File.stream!(chunk_size, read_ahead: false)
      |> Stream.take(div(remaining, chunk_size))
      |> Enum.reduce_while({state, "", false}, fn chunk, {state, buffer, skipping?} ->
        result = lines(chunk, buffer, skipping?, %{state | bytes: state.bytes + byte_size(chunk)})
        if elem(result, 0).count >= state.max_records, do: {:halt, result}, else: {:cont, result}
      end)

    {:ok, stat} = File.stat(path)
    complete? = state.bytes - before >= stat.size
    state = if complete? and buffer != "" and not skipping?, do: add_line(buffer, state), else: state
    %{state | missing: state.missing or not complete? or skipping?}
  rescue
    _error -> %{state | missing: true, bytes: state.max_bytes}
  end

  defp read_bounded(_path, state, _remaining), do: %{state | missing: true, bytes: state.max_bytes}

  defp lines(chunk, buffer, skipping?, state) do
    parts = :binary.split(buffer <> chunk, "\n", [:global])
    complete = Enum.drop(parts, -1)
    complete = if skipping?, do: Enum.drop(complete, 1), else: complete
    state = Enum.reduce(complete, state, &add_line/2)
    tail = List.last(parts)
    skipping? = (skipping? and length(parts) == 1) or byte_size(tail) > @max_line
    {%{state | missing: state.missing or skipping?}, if(skipping?, do: "", else: tail), skipping?}
  end

  defp add_line(line, state) when byte_size(line) > @max_line, do: %{state | missing: true}
  defp add_line("", state), do: state

  defp add_line(line, state) do
    case Jsonl.decode_line(line) do
      {:ok, %{"severity" => "critical", "timestamp" => at} = alert} -> add_alert(alert, Common.timestamp(at), state)
      {:ok, _alert} -> state
      :skip -> %{state | missing: true}
    end
  end

  defp add_alert(_alert, nil, state), do: %{state | missing: true}

  defp add_alert(alert, at, state) do
    first = Common.timestamp(state.opts[:range_start])
    last = Common.timestamp(state.opts[:range_end])
    inside? = (is_nil(first) or DateTime.compare(at, first) != :lt) and (is_nil(last) or DateTime.compare(at, last) == :lt)
    keep_alert(alert, inside?, state)
  end

  defp keep_alert(_alert, false, state), do: state
  defp keep_alert(_alert, true, %{count: count, max_records: max} = state) when count >= max, do: %{state | missing: true}

  defp keep_alert(alert, true, state) do
    key = alert["event_id"] || WindowEvents.hash(Map.take(alert, ~w(timestamp topic source_ticket_id message)))
    title = if is_binary(alert["message"]), do: alert["message"], else: ""
    row = WindowEvents.event("incident", "alerts", key, alert["timestamp"], title: title, attrs: Map.take(alert, ~w(topic source_ticket_id severity)))
    %{state | rows: [row | state.rows], count: state.count + 1}
  end
end
