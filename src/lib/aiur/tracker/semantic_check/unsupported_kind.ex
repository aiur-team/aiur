defmodule Aiur.Tracker.SemanticCheck.UnsupportedKind do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  @impl true
  def applies?(settings), do: settings.tracker.kind not in Aiur.Tracker.Registry.kinds()

  @impl true
  def check(settings), do: {:error, {:unsupported_tracker_kind, settings.tracker.kind}}
end
