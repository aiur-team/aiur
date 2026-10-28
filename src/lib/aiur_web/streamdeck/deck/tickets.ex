defmodule AiurWeb.Streamdeck.Deck.Tickets do
  @moduledoc "Ticket keys from the Build window, ordered by attention then queue position."
  alias Aiur.BuildOrder.TicketStatus
  alias AiurWeb.Streamdeck.Deck.Counts

  @order ~w(error command retrying active ci_wait usage_limited parked paused)
  @models %{"claude" => "Claude", "codex" => "Codex", "deepseek" => "DeepSeek", "kimi" => "Kimi"}
  @states TicketStatus.agent_states()

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    case Keyword.fetch(opts, :window) do
      {:ok, result} -> project(result)
      :error -> project(Counts.window(opts))
    end
  end

  @spec keys(map(), :all | {:feature | :epic | :state, term()}) :: [map()]
  def keys(sections, filter \\ :all) do
    now = field(sections, :now) || []
    plan = field(sections, :plan) || []

    now = Enum.filter(now, &filed?/1) |> Enum.sort_by(&{rank(state(&1)), field(&1, :num)})
    plan = Enum.filter(plan, &filed?/1) |> Enum.sort_by(&{field(&1, :qpos) || :unknown, field(&1, :num)})

    (now ++ plan)
    |> Enum.uniq_by(&field(&1, :num))
    |> Enum.filter(&matches?(&1, filter))
    |> Enum.map(&key/1)
  end

  defp project({:ok, window}) do
    source = window |> field(:sources) |> field(:agents)
    status = field(source, :state) || "unavailable"
    keys = Enum.map(keys(field(window, :sections) || %{}), &source_freshness(&1, status))
    %{status: status, keys: keys}
  end

  defp project(_error), do: %{status: "unavailable", keys: []}
  defp filed?(row), do: is_integer(field(row, :num)) and field(row, :num) > 0
  defp state(row), do: row |> field(:agent) |> field(:state)
  defp rank(state), do: Enum.find_index(@order, &(&1 == state)) || if(state in @states, do: 8, else: 9)
  defp matches?(_row, :all), do: true
  defp matches?(row, {:state, :queued}), do: field(row, :sec) == "plan"
  defp matches?(row, {:state, state}), do: field(row, :sec) == "now" and state(row) == state
  defp matches?(row, {kind, key}) when kind in [:feature, :epic], do: field(row, kind) == key

  defp key(row) do
    queued = field(row, :sec) == "plan"
    state = if queued, do: :queued, else: state(row)
    status = TicketStatus.encode(%{sec: field(row, :sec), agent: %{state: state}})
    face = if queued, do: :queued, else: face(state, status.tone)
    pct = if queued, do: nil, else: percent(field(row, :pct))

    %{
      id: field(row, :id) || to_string(field(row, :num)),
      title: field(row, :title),
      state: state,
      label: if(queued, do: "Queued ##{field(row, :qpos) || "?"}", else: status.label),
      face: face,
      pct: pct,
      model: if(!queued, do: model(field(row, :agent)))
    }
    |> render_fields(row, queued)
  end

  defp model(agent), do: field(agent, :name) || @models[field(agent, :model)]

  defp render_fields(key, row, queued) do
    Map.merge(key, %{
      identifier: key.id,
      vendor: row |> field(:agent) |> field(:model),
      bucket: bucket(key.state, queued),
      progress_percent: key.pct,
      progress_freshness: if(is_nil(key.pct), do: "unknown", else: "fresh")
    })
  end

  defp face(state, _tone) when state not in @states, do: :unknown
  defp face(_state, "active"), do: :active
  defp face(_state, "stuck"), do: :stuck
  defp face(_state, "queued"), do: :queued
  defp face(_state, _tone), do: :idle
  # Bucket remains a compatibility token for existing control/footer consumers.
  defp bucket(_face, true), do: :queued
  defp bucket("active", false), do: :running
  defp bucket("paused", false), do: :paused
  defp bucket(_state, false), do: :stuck
  defp source_freshness(%{progress_freshness: "fresh"} = key, status) when status != "ok", do: %{key | progress_freshness: "stale"}
  defp source_freshness(key, _status), do: key
  defp percent(value) when is_integer(value) and value in 0..100, do: value
  defp percent(_value), do: nil
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
