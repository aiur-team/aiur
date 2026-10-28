defmodule AiurWeb.Streamdeck.Deck.SettingsMenu do
  @moduledoc "Pure settings sections and choices, shared by input and frame rendering."

  alias AiurWeb.Streamdeck.Deck.Nav

  @sections [
    {"mic_id", "Mic"},
    {"speaker_id", "Speaker"},
    {"default_view", "View"},
    {"default_sort", "Sort"},
    {"brightness", "Brightness"},
    {"dim_after_seconds", "Sleep"},
    {"instance", "Instance"},
    {"alerts", "Alerts"}
  ]

  @spec sections() :: [{String.t(), String.t()}]
  def sections, do: @sections

  @spec choices(String.t(), map(), map()) :: [map()]
  def choices(section, _settings, nil) when section in ["mic_id", "speaker_id", "instance"], do: []

  def choices(section, settings, devices) when section in ["mic_id", "speaker_id"] do
    available = Map.get(devices, if(section == "mic_id", do: "mics", else: "speakers"), [])
    saved = settings[section]
    missing = if saved && not Enum.any?(available, &(&1["id"] == saved)), do: [%{label: "missing: #{saved}", value: saved}], else: []
    missing ++ Enum.map(available, &%{label: &1["label"], value: &1["id"]})
  end

  def choices("default_view", _settings, _devices), do: values(~w(ticket feature epic fleet))
  def choices("default_sort", _settings, _devices), do: values(~w(state priority title))
  def choices("brightness", _settings, _devices), do: Enum.map(0..10, &%{label: "#{&1 * 10}%", value: &1 * 10})
  def choices("dim_after_seconds", _settings, _devices), do: Enum.map([0, 5, 30, 60, 300, 600, 1800], &%{label: if(&1 == 0, do: "Never", else: "#{&1}s"), value: &1})
  def choices("instance", _settings, devices), do: values(Map.get(devices, "instances") || [])

  def choices("alerts", settings, _devices) do
    for kind <- ~w(command ci_red error usage_limited), flag <- ~w(flash chime) do
      enabled = settings["alerts"][kind][flag]
      %{label: "#{kind} #{flag}: #{if(enabled, do: "on", else: "off")}", value: put_in(settings["alerts"], [kind, flag], not enabled)}
    end
  end

  @spec summary(String.t(), map(), map()) :: String.t()
  def summary(section, settings, devices) do
    if available?(section, devices) do
      case section do
        "alerts" ->
          "Flash / chime"

        _ ->
          choices(section, settings, devices)
          |> Enum.find(%{label: if(is_nil(settings[section]), do: "Default", else: to_string(settings[section]))}, &(&1.value == settings[section]))
          |> Map.fetch!(:label)
      end
    else
      "Unavailable"
    end
  end

  @spec available?(String.t() | nil, map() | nil) :: boolean()
  def available?(section, devices) when section in ["mic_id", "speaker_id", "instance"] do
    key = %{"mic_id" => "mics", "speaker_id" => "speakers", "instance" => "instances"}[section]
    is_map(devices) and is_list(Map.get(devices, key)) and get_in(devices, ["availability", key]) != false
  end

  def available?(_section, _devices), do: true

  @spec move(non_neg_integer(), integer(), non_neg_integer()) :: non_neg_integer()
  def move(index, ticks, count), do: index |> Kernel.+(ticks) |> max(0) |> min(max(count - 1, 0))

  @spec reduce(Nav.t(), map(), map()) :: :pass | {Nav.t(), [Nav.effect()]}
  def reduce(%{surface: :grid, stack: []} = nav, %{"kind" => "dial_long_press", "index" => 3}, _snapshot),
    do: {%{nav | surface: :settings, settings: %{section: nil, cursor: 0, return_surface: :grid, notice: nil}}, []}

  def reduce(%{surface: surface}, _input, _snapshot) when surface != :settings, do: :pass

  def reduce(nav, %{"kind" => "dial_long_press", "index" => 3}, _snapshot) do
    menu = nav.settings
    if is_nil(menu.section), do: {%{nav | surface: menu.return_surface}, []}, else: {%{nav | settings: %{menu | section: nil, cursor: 0, notice: nil}}, []}
  end

  def reduce(nav, %{"kind" => "dial_turn", "index" => 0, "ticks" => ticks}, snapshot) do
    count = if is_nil(nav.settings.section), do: 8, else: length(options(nav.settings.section, snapshot))
    {%{nav | settings: %{nav.settings | cursor: move(nav.settings.cursor, ticks, count), notice: nil}}, []}
  end

  def reduce(nav, %{"kind" => "key_press", "index" => index}, snapshot), do: select(nav, index + if(is_nil(nav.settings.section), do: 0, else: div(nav.settings.cursor, 8) * 8), snapshot)
  def reduce(nav, %{"kind" => "dial_press", "index" => 0}, snapshot), do: select(nav, nav.settings.cursor, snapshot)
  def reduce(nav, _input, _snapshot), do: {nav, []}

  @spec clamp(Nav.t(), map()) :: Nav.t()
  def clamp(%{surface: :settings, settings: %{section: section}} = nav, snapshot) when not is_nil(section),
    do: %{nav | settings: %{nav.settings | cursor: move(nav.settings.cursor, 0, length(options(section, snapshot)))}}

  def clamp(nav, _snapshot), do: nav

  @spec options(String.t(), map()) :: [map()]
  def options(section, %{status: :ok, settings: settings, devices: devices}), do: if(available?(section, devices), do: choices(section, settings, devices), else: [])
  def options(_section, _snapshot), do: []

  defp select(%{settings: %{section: nil}} = nav, index, _snapshot) do
    {section, _label} = Enum.at(sections(), index)
    {%{nav | settings: %{nav.settings | section: section, cursor: 0, notice: nil}}, []}
  end

  defp select(nav, index, snapshot) do
    case Enum.at(options(nav.settings.section, snapshot), index) do
      nil -> {nav, []}
      choice -> {%{nav | settings: %{nav.settings | notice: nil}}, [{:settings_set, %{nav.settings.section => choice.value}}]}
    end
  end

  defp values(values), do: Enum.map(values, &%{label: &1, value: &1})
end
