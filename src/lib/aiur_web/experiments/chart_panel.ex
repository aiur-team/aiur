defmodule AiurWeb.Experiments.ChartPanel do
  @moduledoc false
  use Phoenix.Component
  alias AiurWeb.Experiments.Charts

  attr(:detail, :map, required: true)
  attr(:metric, :map, default: nil)
  @spec panel(map()) :: Phoenix.LiveView.Rendered.t()
  def panel(assigns) do
    ~H"""
    <div id="exp-charts">
      <div :if={@metric}>
        <h3>Median changes</h3>
        {Charts.forest(@detail.chart_metrics)}
        <nav class="exp-metric-links" aria-label="Chart metric">
          <.link :for={item <- @detail.chart_metrics} patch={path(@detail, item.ref, @detail.stratum)} aria-current={if @metric.ref == item.ref, do: "true"}>{item.label}</.link>
        </nav>
        <form class="exp-metric-select" phx-change="select-metric">
          <label for="exp-metric">Chart metric</label>
          <select id="exp-metric" name="metric"><option :for={item <- @detail.chart_metrics} value={item.ref} selected={item.ref == @metric.ref}>{item.label}</option></select>
        </form>
        <nav :if={@detail.strata != []} class="exp-strata" aria-label="Chart stratum">
          <.link patch={path(@detail, @metric.ref, nil)} aria-current={if is_nil(@detail.stratum), do: "true"}>All strata</.link>
          <.link :for={stratum <- @detail.strata} patch={path(@detail, @metric.ref, stratum)} aria-current={if @detail.stratum == stratum, do: "true"}>{stratum}</.link>
        </nav>
        <h3>Distribution: {@metric.label}</h3>
        <p :if={Enum.all?(@metric.groups, &(&1.points == []))}>Sample-level evidence is unavailable. Stored group summaries are shown.</p>
        {Charts.distribution(@metric)}
        <h3>Time series: {@metric.label}</h3>
        {Charts.time_series(@metric, @detail)}
        <h3>Samples and power</h3>
        {Charts.power(@detail.chart_metrics, @detail)}
      </div>
    </div>
    """
  end

  @spec path(map(), String.t(), String.t() | nil) :: String.t()
  def path(detail, metric, stratum) do
    query = if stratum, do: [{"metric", metric}, {"stratum", stratum}], else: [{"metric", metric}]
    "/experiments/" <> URI.encode(detail.id, &URI.char_unreserved?/1) <> "?" <> URI.encode_query(query)
  end
end
