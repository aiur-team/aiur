defmodule AiurWeb.Streamdeck.Render.Style do
  @moduledoc false

  # Snapshot of the existing key-face contract; the renderer owns these tokens.
  @states %{
    "alert" => %{glow: ["#ffc061", "#e08a1e"], face: ["#241d0e", "#15110a"], accent: "#ffcf87", label: "Needs input"},
    "stuck" => %{glow: ["#ff6a5e", "#c0392b"], face: ["#271317", "#160c0e"], accent: "#ff9a90", label: "Stuck"},
    "running" => %{glow: ["#3f8bff", "#7b4bf5"], face: ["#18212d", "#0f151d"], accent: "#9fd0ff", label: "Running"},
    "paused" => %{glow: ["#4a4d55", "#33363d"], face: ["#1e2025", "#131419"], accent: "#c2c6cf", label: "Paused"},
    "queued" => %{glow: ["#3a3f47", "#23262c"], face: ["#191b21", "#111318"], accent: "#9096a4", label: "Unstarted"}
  }

  @spec state(atom() | String.t()) :: map()
  def state(bucket), do: Map.fetch!(@states, to_string(bucket))
end
