defmodule AiurWeb.Experiments.Charts do
  @moduledoc "Accessible inline SVG views of facade-supplied experiment evidence."
  alias AiurWeb.Experiments.Charts.{Distribution, Forest, Power, TimeSeries}

  @spec forest([map()]) :: Phoenix.HTML.safe()
  def forest(metrics), do: Phoenix.HTML.raw(Forest.render(metrics))

  @spec distribution(map()) :: Phoenix.HTML.safe()
  def distribution(metric), do: Phoenix.HTML.raw(Distribution.render(metric))

  @spec time_series(map(), map()) :: Phoenix.HTML.safe()
  def time_series(metric, detail), do: Phoenix.HTML.raw(TimeSeries.render(metric, detail))

  @spec power([map()], map()) :: Phoenix.HTML.safe()
  def power(metrics, detail), do: Phoenix.HTML.raw(Power.render(metrics, detail))
end
