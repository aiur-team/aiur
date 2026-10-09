defmodule Aiur.Tracker.SemanticCheck.LinearToken do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  @impl true
  def applies?(settings), do: settings.tracker.kind == "linear" and not is_binary(settings.tracker.linear.api_key)

  @impl true
  def check(_settings), do: {:error, :missing_linear_api_token}
end
