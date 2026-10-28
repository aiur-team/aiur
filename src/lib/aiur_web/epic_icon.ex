defmodule AiurWeb.EpicIcon do
  @moduledoc "Shared epic-to-Heroicons SVG resolver for dashboard and device images."

  alias Aiur.Heroicons

  # Epic (build lane) -> Heroicons v2 outline icon name. "adhoc" is the runtime
  # Ad Hoc overlay lane, tracked separately from the planning lanes.
  @lane_icons %{
    "plan-graph" => "share",
    "runtime" => "bolt",
    "dashboard-ui" => "rectangle-group",
    "accounting" => "banknotes",
    "platform" => "server-stack",
    "adhoc" => "sparkles",
    # Additional lanes used by planning packs (e.g. the CropTracker demo).
    "core" => "cube",
    "web" => "window",
    "data" => "circle-stack",
    "api" => "cloud",
    "billing" => "credit-card"
  }

  @spec svg(term()) :: String.t()
  def svg(lane) when is_binary(lane), do: lane |> then(&Map.get(@lane_icons, &1, &1)) |> Heroicons.svg()
  def svg(_lane), do: Heroicons.svg(nil)
end
