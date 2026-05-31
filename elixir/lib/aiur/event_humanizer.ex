defmodule Aiur.EventHumanizer do
  @moduledoc """
  Behaviour for humanizing agent event messages in the status dashboard.

  Each coding agent backend (Codex, Claude) emits different event names and
  payload structures. Implementations translate raw payloads into short,
  human-readable strings for the dashboard.
  """

  @callback humanize_method(method :: String.t(), payload :: map()) :: String.t()
end
