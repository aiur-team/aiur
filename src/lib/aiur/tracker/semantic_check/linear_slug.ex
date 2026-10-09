defmodule Aiur.Tracker.SemanticCheck.LinearSlug do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  @impl true
  def applies?(settings), do: settings.tracker.kind == "linear" and not is_binary(settings.tracker.linear.project_slug)

  @impl true
  def check(_settings), do: {:error, :missing_linear_project_slug}
end
