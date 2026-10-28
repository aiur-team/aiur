defmodule AiurWeb.Streamdeck.Deck.SettingsMenu do
  @moduledoc "Pure settings sections and choices, shared by input and frame rendering."

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
  def choices("instance", _settings, devices), do: values(Map.get(devices, "instances", []))

  def choices("alerts", settings, _devices) do
    for kind <- ~w(command ci_red error usage_limited), flag <- ~w(flash chime) do
      enabled = settings["alerts"][kind][flag]
      %{label: "#{kind} #{flag}: #{if(enabled, do: "on", else: "off")}", value: put_in(settings["alerts"], [kind, flag], not enabled)}
    end
  end

  @spec summary(String.t(), map(), map()) :: String.t()
  def summary(section, settings, devices) do
    case section do
      "alerts" ->
        "Flash / chime"

      _ ->
        choices(section, settings, devices)
        |> Enum.find(%{label: if(is_nil(settings[section]), do: "Default", else: to_string(settings[section]))}, &(&1.value == settings[section]))
        |> Map.fetch!(:label)
    end
  end

  @spec move(non_neg_integer(), integer(), non_neg_integer()) :: non_neg_integer()
  def move(index, ticks, count), do: index |> Kernel.+(ticks) |> max(0) |> min(max(count - 1, 0))

  defp values(values), do: Enum.map(values, &%{label: &1, value: &1})
end
