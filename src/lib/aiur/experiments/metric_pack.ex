defmodule Aiur.Experiments.MetricPack do
  @moduledoc "Contract for built-in metric packs; consumer packs use declarative sources."
  alias Aiur.Experiments.{Metric, Observation}
  @callback id() :: String.t()
  @callback version() :: String.t()
  @callback metrics() :: [Metric.t()]
  @callback observations([String.t()], map(), map()) :: %{String.t() => {map(), [Observation.t()]}}
end
