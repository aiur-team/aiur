defmodule Aiur.Commands.Defaults do
  @moduledoc false

  @spec default_metrics() :: module()
  def default_metrics, do: Aiur.DecisionMetrics

  @spec default_attention() :: module()
  def default_attention, do: Aiur.DecisionAttention

  @spec default_api() :: module()
  def default_api, do: Aiur.DecisionApi
end
