defmodule AiurWeb.Streamdeck.Deck.Fleet do
  @moduledoc "Eight Fleet categories, sharing the Ticket population and Deck counting module."
  alias AiurWeb.OperatorControlCenter.PauseState
  alias AiurWeb.Streamdeck.Deck.{Counts, Tickets}
  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2]

  @categories [
    {:active, "Active", ["active", :unknown]},
    {:command, "Needs command", ["command"]},
    {:error, "Error / retrying", ["error", "retrying"]},
    {:ci_wait, "Waiting for CI", ["ci_wait"]},
    {:usage_limited, "Usage limited", ["usage_limited"]},
    {:paused, "Parked / paused", ["parked", "paused"]},
    {:queued, "Queued backlog", [:queued]},
    {:capacity, "Capacity", [:live]}
  ]

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    window = Keyword.get_lazy(opts, :window, fn -> Counts.window(opts) end)

    case window do
      {:ok, data} ->
        status = data |> field(:sources) |> field(:agents) |> field(:state)
        if status in ["ok", "stale"], do: Map.put(project(data, opts), :status, status), else: unavailable(data, opts)

      _ ->
        %{status: "unavailable", keys: [], strip: %{daemon: "unknown", heartbeat_age_s: nil, capacity_stale: nil, global_pause: nil}}
    end
  end

  @spec navigation(map()) :: [map()]
  def navigation(fleet), do: Enum.map(field(fleet, :keys) || [], &navigation_key/1)

  defp navigation_key(nil), do: nil

  defp navigation_key(key) do
    states = Enum.find_value(@categories, [], fn {cat, _title, states} -> if Atom.to_string(cat) == to_string(field(key, :cat)), do: states end)
    tickets = Enum.map(field(key, :tickets) || [], &Map.put(&1, :id, field(&1, :id)))
    key |> Map.put(:id, field(key, :id)) |> Map.put(:states, states) |> Map.put(:tickets, tickets)
  end

  defp unavailable(data, opts), do: %{status: "unavailable", keys: [], strip: strip(data, opts)}

  defp project(data, opts) do
    sections = field(data, :sections) || %{}
    counts = opts |> Keyword.get_lazy(:counts, fn -> Counts.read(window: {:ok, data}) end) |> Counts.categories()
    keys = Enum.map(@categories, &category(&1, counts, sections, field(data, :capacity)))
    %{status: "ok", keys: keys, strip: strip(data, opts)}
  end

  defp category({cat, title, states}, counts, sections, capacity) do
    count = Map.get(counts, cat)
    unknown = if cat == :active, do: counts.unknown, else: 0
    label = if unknown > 0, do: "#{count} · #{unknown}?", else: to_string(count)
    label = if cat == :capacity, do: "#{counts.live} / #{field(capacity, :max) || "—"}", else: label

    key = %{
      id: Atom.to_string(cat),
      cat: cat,
      count: count,
      unknown: unknown,
      states: states,
      title: title,
      label: label,
      face: :idle,
      bucket: :paused,
      tickets: Tickets.keys(sections, {:state, states})
    }

    if cat == :capacity, do: Map.merge(key, %{live: counts.live, max: field(capacity, :max)}), else: key
  end

  defp strip(data, opts) do
    daemon = field(data, :daemon)
    capacity = field(data, :capacity)
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    heartbeat = field(daemon, :heartbeat_at)
    age = if is_integer(heartbeat), do: max(div(now - heartbeat, 1_000), 0)

    %{
      daemon: field(daemon, :state) || "unknown",
      heartbeat_age_s: age,
      capacity_max: field(capacity, :max),
      capacity_stale: field(capacity, :stale),
      global_pause: Keyword.get_lazy(opts, :global_pause, &pause/0)
    }
  end

  defp pause do
    orchestrator = AiurWeb.EndpointConfig.get(:orchestrator) || Aiur.Orchestrator
    PauseState.pause_state(orchestrator)
  end
end
