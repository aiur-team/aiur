defmodule AiurWeb.Streamdeck.Render.Style do
  @moduledoc false

  # Renderer-owned visual tokens; no mirrored visual contract remains.
  @states %{
    "alert" => %{
      glow: ["#ffc061", "#e08a1e"],
      face: ["#241d0e", "#15110a"],
      accent: "#ffcf87",
      label: "Needs input"
    },
    "stuck" => %{
      glow: ["#ff6a5e", "#c0392b"],
      face: ["#271317", "#160c0e"],
      accent: "#ff9a90",
      label: "Stuck"
    },
    "running" => %{
      glow: ["#3f8bff", "#7b4bf5"],
      face: ["#18212d", "#0f151d"],
      accent: "#9fd0ff",
      label: "Running"
    },
    "paused" => %{
      glow: ["#4a4d55", "#33363d"],
      face: ["#1e2025", "#131419"],
      accent: "#c2c6cf",
      label: "Paused"
    },
    "queued" => %{
      glow: ["#3a3f47", "#23262c"],
      face: ["#191b21", "#111318"],
      accent: "#9096a4",
      label: "Unstarted"
    }
  }

  @spec state(atom() | String.t()) :: map()
  def state(:active), do: state("running")
  def state(:idle), do: state("paused")
  def state(:unknown), do: state("paused")
  def state("active"), do: state("running")
  def state("idle"), do: state("paused")
  def state("unknown"), do: state("paused")

  def state(bucket) do
    case Map.fetch(@states, to_string(bucket)) do
      {:ok, style} -> style
      :error -> raise ArgumentError, "unhandled Stream Deck state: #{inspect(bucket)}"
    end
  end

  @spec known_state?(term()) :: boolean()
  def known_state?(bucket), do: Map.has_key?(@states, to_string(bucket))

  @spec bucket_rank!(term()) :: non_neg_integer()
  def bucket_rank!(bucket) do
    case Enum.find_index(~w(alert stuck running paused queued), &(&1 == to_string(bucket))) do
      nil -> raise ArgumentError, "unhandled Stream Deck state: #{inspect(bucket)}"
      rank -> rank
    end
  end

  @spec progress_color(number()) :: String.t()
  def progress_color(percent) when is_number(percent),
    do: if(percent >= 100, do: "#74d47f", else: "#3fb950")

  @badges %{
    "EMIT" => "#9fd0ff",
    "CONSUME" => "#88e0a6",
    "AGENT" => "#9fd0ff",
    "SYSTEM" => "#ffcf87",
    "INFO" => "#c2c6cf"
  }
  @spec direction_badge!(term()) :: map()
  def direction_badge!(badge), do: %{"color" => Map.fetch!(@badges, to_string(badge))}
end
