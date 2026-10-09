defmodule Aiur.Config.Capture do
  @moduledoc false

  @spec telemetry_enabled?(term()) :: boolean()
  def telemetry_enabled?({:ok, %{observability: observability}}), do: observability.telemetry_enabled
  def telemetry_enabled?(_settings), do: true

  @spec capture_github_facts?(term()) :: boolean()
  def capture_github_facts?({:ok, %{observability: %{capture_github_facts: enabled?}}}), do: enabled?
  def capture_github_facts?(_settings), do: true
end
