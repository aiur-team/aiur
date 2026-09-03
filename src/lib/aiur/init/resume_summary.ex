defmodule Aiur.Init.ResumeSummary do
  @moduledoc false

  @spec prewarm_line(map() | nil) :: String.t() | nil
  def prewarm_line(nil), do: nil
  def prewarm_line(%{"enabled" => true}), do: "prewarm: enabled"
  def prewarm_line(_prewarm), do: "prewarm: declined"

  @spec alerts_line(map()) :: String.t() | nil
  def alerts_line(config) do
    case config["alerts"] do
      %{"enabled" => enabled} -> "alerts: #{enabled}"
      _ -> nil
    end
  end

  @spec optional_section_line(String.t(), map() | nil, (map() -> String.t())) :: String.t() | nil
  def optional_section_line(_label, nil, _detail), do: nil
  def optional_section_line(label, %{"enabled" => false}, _detail), do: "#{label}: declined"

  # ElevenLabs predates its enabled key, so a present legacy section remains
  # enabled unless it explicitly records enabled: false.
  def optional_section_line(label, section, detail), do: "#{label}: enabled (#{detail.(section)})"

  # The credential is secret, so report only whether one is configured.
  @spec elevenlabs_key_state(map() | term()) :: String.t()
  def elevenlabs_key_state(%{"api_key" => key}) when is_binary(key) and key != "", do: "api_key set"
  def elevenlabs_key_state(_elevenlabs), do: "api_key not set"

  @spec format_routing(map() | term()) :: String.t()
  def format_routing(routing) when is_map(routing) do
    routing
    |> Enum.sort_by(fn {level, _} -> to_string(level) end)
    |> Enum.map_join(", ", fn {level, value} -> "#{level}:#{value}" end)
  end

  def format_routing(_routing), do: ""
end
