defmodule Aiur.Tracker.SemanticCheck.Settings do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  @impl true
  def applies?(_settings), do: true

  @impl true
  def check(settings) do
    config = Aiur.Tracker.Registry.config_module(settings.tracker.kind)

    if config && Code.ensure_loaded?(config) && function_exported?(config, :validate_settings, 1),
      do: config.validate_settings(settings),
      else: :continue
  end
end
