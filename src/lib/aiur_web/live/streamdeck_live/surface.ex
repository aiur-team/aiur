defmodule AiurWeb.StreamdeckLive.Surface do
  @moduledoc """
  Pure descriptors for the Stream Deck emulator: the eight agent keys, the
  touch-strip segments (summary, provider meters, pager), the dial math that
  maps a dial value onto a grid window, and the knob readouts.
  """

  alias Aiur.{CodingAgent, Config}
  alias AiurWeb.{StreamdeckKeyFaceContract, StreamdeckStrip}

  @spec key_descriptors([map()], non_neg_integer()) :: [map()]
  def key_descriptors(agents, column_offset) do
    for slot <- 0..7 do
      column = rem(slot, 4)
      row = div(slot, 4)

      case Enum.at(agents, (column_offset + column) * 2 + row) do
        nil -> empty_key(slot + 1)
        agent -> agent_key(slot + 1, agent)
      end
    end
  end

  defp agent_key(slot, agent) do
    bucket = Map.fetch!(agent, :bucket)
    footer = StreamdeckKeyFaceContract.footer_for_agent(bucket, agent)

    key(
      slot,
      Atom.to_string(bucket),
      Map.get(agent, :identifier),
      Map.get(agent, :title, "Untitled"),
      footer.label,
      Map.get(agent, :progress_percent),
      identifier: Map.get(agent, :identifier),
      control_action: control_action(bucket),
      priority?: Map.get(agent, :priority, false),
      icon: Map.get(agent, :icon),
      vendor_logo: Map.get(agent, :vendor_logo),
      dependency_ready?: footer.ready?,
      dependency: footer.dependency,
      progress_freshness: Map.get(agent, :progress_freshness),
      style: key_style(Map.get(agent, :progress_percent))
    )
  end

  defp key(slot, bucket, ticket, title, label, progress, opts) do
    %{
      slot: slot,
      bucket: bucket,
      ticket: ticket,
      title: title,
      label: label,
      progress: progress,
      progress_freshness: Keyword.get(opts, :progress_freshness),
      priority?: Keyword.get(opts, :priority?, false),
      dependency_ready?: Keyword.get(opts, :dependency_ready?, false),
      icon: Keyword.get(opts, :icon),
      vendor_logo: Keyword.get(opts, :vendor_logo),
      dependency: Keyword.get(opts, :dependency),
      identifier: Keyword.get(opts, :identifier, ticket),
      control_action: Keyword.get(opts, :control_action),
      style: Keyword.fetch!(opts, :style),
      empty?: false
    }
  end

  defp empty_key(slot),
    do: %{slot: slot, bucket: "empty", identifier: nil, control_action: nil, style: nil, empty?: true}

  @spec screen_descriptors(map(), map(), integer(), map() | nil) :: [map()]
  def screen_descriptors(grid, usage, current_page, focus) do
    live = live_count(grid)
    families = configured_provider_families()

    [
      %{kind: :summary, label: "SUMMARY", logo: "/aiur-logo.png", observed?: grid.total > 0, live: live, remaining: max(grid.total - live, 0), meters: []}
      | CodingAgent.provider_descriptors()
        |> Enum.filter(&MapSet.member?(families, &1.provider))
        |> Enum.map(&provider_segment(&1, usage))
    ] ++ [pager_segment(grid, current_page, focus)]
  end

  # Provider segments reflect only the backends actually configured for this
  # run (agent.priority / agent.backend_configs), matching the dispatchable
  # set the Units page resolves. Unconfigured providers are hidden entirely.
  defp configured_provider_families do
    provider_families(CodingAgent.dispatchable_backends(Config.agent_backend_configs()))
  rescue
    _error -> provider_families(CodingAgent.dispatchable_backends())
  end

  defp provider_families(backends) do
    backends
    |> Enum.map(&CodingAgent.family_for/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.to_atom/1)
    |> MapSet.new()
  end

  # A focused command takes the pager segment over: the dots give way to the
  # agent being controlled, matching the design's CONTROLLING relabel.
  @spec pager_segment(map(), integer(), map() | nil) :: map()
  def pager_segment(_grid, current_page, focus) when not is_nil(focus) do
    %{
      kind: :pager,
      label: "CONTROLLING",
      observed?: true,
      pages: [],
      current_page: current_page,
      focus_label: "##{focus.identifier}",
      meters: []
    }
  end

  def pager_segment(grid, current_page, _focus) do
    %{
      kind: :pager,
      label: "MORE AGENTS",
      observed?: grid.windows > 1,
      pages: pager_pages(grid.windows),
      current_page: current_page,
      focus_label: nil,
      meters: []
    }
  end

  @spec mode_pager_focus(atom(), map() | nil) :: map() | nil
  def mode_pager_focus(mode, active) when mode in [:cmd, :logs, :settings] and not is_nil(active), do: active
  def mode_pager_focus(_mode, _active), do: nil

  defp live_count(grid), do: Enum.count(grid.agents, &(&1.bucket == :running))

  defp provider_segment(descriptor, usage) do
    provider = Atom.to_string(descriptor.provider)
    meter = Map.get(usage, provider)

    %{
      kind: :provider,
      provider: provider,
      label: Enum.join(Enum.filter([descriptor.label, StreamdeckStrip.summary_label(meter)], &is_binary/1), " · "),
      logo: descriptor.logo,
      observed?: observed_provider?(meter),
      meters: [provider_meter("session", "Session", meter), provider_meter("weekly", "Weekly", meter)]
    }
  end

  defp provider_meter(key, label, meter) do
    window = if observed_provider?(meter), do: meter |> get_value("windows", %{}) |> get_value(key), else: nil
    percent = window_percentage(window)
    freshness = window_freshness(window)

    %{
      key: key,
      label: label,
      percent: percent,
      metadata: meter_metadata(window, freshness),
      observed?: is_integer(percent),
      freshness: freshness
    }
  end

  defp observed_provider?(%{} = meter), do: get_value(meter, "state") in [:observed, "observed"]
  defp observed_provider?(_meter), do: false

  defp window_metadata(window) when is_map(window) do
    case get_value(window, "remaining") do
      remaining when is_binary(remaining) and remaining != "" -> remaining
      _ -> window |> get_value("resets_at") |> reset_label()
    end
  end

  defp window_metadata(_window), do: nil

  defp window_freshness(window) when is_map(window) do
    case get_value(window, "freshness") do
      freshness when freshness in [:fresh, "fresh", :partial, "partial", :stale, "stale"] -> to_string(freshness)
      _ -> "unknown"
    end
  end

  defp window_freshness(_window), do: "unknown"

  defp meter_metadata(window, _freshness) do
    [window_metadata(window)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      metadata -> metadata
    end
  end

  defp reset_label(%DateTime{} = reset), do: "#{weekday(reset)} #{hour_label(reset)}"

  defp reset_label(reset) when is_binary(reset) do
    case DateTime.from_iso8601(reset) do
      {:ok, datetime, _offset} -> reset_label(datetime)
      _ -> nil
    end
  end

  defp reset_label(_reset), do: nil

  defp weekday(%DateTime{} = datetime), do: Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(DateTime.to_date(datetime)) - 1)
  defp hour_label(%DateTime{hour: hour}), do: "#{rem(hour + 11, 12) + 1}#{if(hour < 12, do: "AM", else: "PM")}"

  # An unknown percentage gets no fill hue at all — the same rule the provider
  # meters already follow with `observed?`. Colouring it would paint a measured
  # 0% onto a ticket nobody measured.
  defp key_style(progress) when is_number(progress), do: "--sd-progress-fill: #{StreamdeckKeyFaceContract.progress_color(progress)}"
  defp key_style(_progress), do: nil

  defp control_action(:running), do: "pause"
  defp control_action(:paused), do: "resume"
  defp control_action(_bucket), do: nil

  @spec clamp_page(term(), integer()) :: integer()
  def clamp_page(page, windows) when is_integer(page), do: clamp(page, 0, max(windows - 1, 0))
  def clamp_page(_page, windows), do: clamp_page(0, windows)

  @spec max_column_offset(non_neg_integer()) :: non_neg_integer()
  def max_column_offset(agent_count), do: max(0, ceil(agent_count / 2) - 4)
  @spec clamp_column_offset(number(), non_neg_integer()) :: number()
  def clamp_column_offset(offset, agent_count), do: clamp(offset, 0, max_column_offset(agent_count))
  @spec column_offset_from_dial(number(), non_neg_integer()) :: integer()
  def column_offset_from_dial(value, agent_count), do: round(clamp(value, 0, 100) / 100 * max_column_offset(agent_count))

  @spec dial_value_from_offset(number(), non_neg_integer()) :: integer()
  def dial_value_from_offset(offset, agent_count) do
    max_offset = max_column_offset(agent_count)
    if max_offset == 0, do: 0, else: clamp(round(offset / max_offset * 100), 0, 100)
  end

  @spec current_window(integer(), non_neg_integer()) :: integer()
  def current_window(column_offset, agent_count) do
    max_offset = max_column_offset(agent_count)
    windows = max(1, ceil(agent_count / 8))

    if column_offset >= max_offset,
      do: windows - 1,
      else: min(div(max(column_offset, 0), 4), windows - 1)
  end

  defp pager_pages(0), do: []
  defp pager_pages(windows), do: 0..(windows - 1)

  @spec clamp(number(), number(), number()) :: number()
  def clamp(value, min, max), do: value |> max(min) |> min(max)

  defp get_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    _ -> Map.get(map, key, default)
  end

  defp window_percentage(window) when is_map(window) do
    used_percent = get_value(window, "used_percent")
    used = get_value(window, "used")
    limit = get_value(window, "limit")

    cond do
      is_number(used_percent) -> round(used_percent)
      is_number(used) and is_number(limit) and limit > 0 -> round(used / limit * 100)
      true -> nil
    end
  end

  defp window_percentage(_window), do: nil

  @spec knob_descriptors(number(), integer(), atom(), map()) :: [map()]
  def knob_descriptors(dial_value \\ 0, windows \\ 0, mode \\ :grid, logs \\ %{}) do
    back_hint =
      case mode do
        :cmd -> StreamdeckStrip.hint(0, 0, "BACK")
        :settings -> StreamdeckStrip.hint(0, 0, "BACK")
        :commands -> StreamdeckStrip.hint(0, 0, "BACK")
        :logs -> StreamdeckStrip.hint(Map.get(logs, :transcript_offset, 0), Map.get(logs, :transcript_max_offset, 0), "BACK")
        _ -> nil
      end

    events_hint =
      if mode == :logs,
        do: StreamdeckStrip.hint(Map.get(logs, :events_offset, 0), Map.get(logs, :events_max_offset, 0), "EVENTS"),
        else: nil

    [
      %{label: "Focus", value: "62", angle: 138, hint: back_hint},
      %{label: "Volume", value: "74", angle: 174, hint: nil},
      %{label: "Speed", value: "48", angle: 78, hint: nil},
      %{
        label: "Page",
        value: String.pad_leading(to_string(dial_value), 2, "0"),
        angle: if(windows > 0, do: dial_value / 100 * 270 - 135, else: -135),
        hint: events_hint
      }
    ]
  end
end
