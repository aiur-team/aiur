defmodule Aiur.BuildOrder.Index.EpicProgress do
  @moduledoc false
  alias Aiur.Config.Schema.GeneralEpic

  @spec compute(list(), map(), map(), map()) :: map()
  def compute(general, rows, history, sources) do
    labelled_rows = Enum.filter(rows, fn {_id, row} -> Map.has_key?(history, row.num) end)
    source_reason = source_reason(sources)
    observed_at = observed_at(sources)

    epics = Map.new(general, fn epic -> {epic.key, progress(epic, labelled_rows, history, source_reason, observed_at)} end)
    %{epics: epics, meta: meta(general, labelled_rows, history, source_reason, observed_at)}
  end

  defp observed_at(sources) do
    timestamps = Enum.map([:history, :agents, :queue, :open_tickets], &get_in(sources, [&1, :observed_at]))
    if Enum.all?(timestamps, &is_integer/1), do: Enum.min(timestamps)
  end

  defp meta(_general, _rows, _history, reason, observed_at) when not is_nil(reason),
    do: %{unmatched: nil, observed_at: observed_at, reason: reason}

  defp meta(general, rows, history, nil, observed_at) do
    if incomplete_labels?(rows, history) do
      %{unmatched: nil, observed_at: observed_at, reason: incomplete_reason()}
    else
      unmatched =
        Enum.count(rows, fn {_id, row} ->
          labels = history |> Map.fetch!(row.num) |> Map.fetch!(:labels)
          not Enum.any?(general, &GeneralEpic.matches?(&1, labels))
        end)

      %{unmatched: unmatched, observed_at: observed_at, reason: nil}
    end
  end

  defp progress(_epic, _rows, _history, reason, now) when not is_nil(reason),
    do: %{closed: nil, open: nil, total: nil, observed_at: now, reason: reason}

  defp progress(epic, rows, history, nil, now) do
    if incomplete_for_epic?(epic, rows, history) do
      %{closed: nil, open: nil, total: nil, observed_at: now, reason: incomplete_reason()}
    else
      count_progress(epic, rows, history, now)
    end
  end

  defp count_progress(epic, rows, history, now) do
    members = Enum.filter(rows, fn {_id, row} -> GeneralEpic.matches?(epic, Map.fetch!(history, row.num).labels) end)

    closed = Enum.count(members, fn {_id, row} -> row.sec == "hist" end)
    total = length(members)
    %{closed: closed, open: total - closed, total: total, observed_at: now, reason: nil}
  end

  defp source_reason(sources) do
    case source_failures(sources) do
      [] -> nil
      failures -> Enum.join(failures, ", ")
    end
  end

  defp incomplete_for_epic?(epic, rows, history) do
    Enum.any?(rows, fn {_id, row} ->
      case Map.get(history, row.num) do
        %{labels: labels} = history_row when is_list(labels) ->
          Map.get(history_row, :labels_complete) == false and not GeneralEpic.matches?(epic, labels)

        _ ->
          true
      end
    end)
  end

  defp incomplete_reason, do: "Some ticket labels are incomplete"

  defp source_failures(sources) do
    sources
    |> Enum.filter(fn {key, source} -> key in [:history, :agents, :queue, :open_tickets] and source_incomplete?(key, source) end)
    |> Enum.map(fn {key, source} -> "#{key}:#{source.reason || source.state}" end)
  end

  defp source_incomplete?(key, source),
    do: source.state in ["unavailable", "incomplete", "unsupported"] or (key == :open_tickets and source.truncated)

  defp incomplete_labels?(rows, history) do
    Enum.any?(rows, fn {_id, row} ->
      case Map.get(history, row.num) do
        %{labels: labels} = history_row when is_list(labels) -> Map.get(history_row, :labels_complete) == false
        _ -> true
      end
    end)
  end
end
