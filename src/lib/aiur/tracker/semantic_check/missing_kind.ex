defmodule Aiur.Tracker.SemanticCheck.MissingKind do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  @impl true
  def applies?(settings), do: is_nil(settings.tracker.kind)

  @impl true
  def check(_settings), do: {:error, :missing_tracker_kind}
end
