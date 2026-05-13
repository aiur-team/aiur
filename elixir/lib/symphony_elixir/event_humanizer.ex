defmodule SymphonyElixir.EventHumanizer do
  @moduledoc """
  Behaviour for humanizing agent event messages in the status dashboard.

  Each coding agent backend (Codex, Claude) emits different event names and
  payload structures. Implementations translate raw payloads into short,
  human-readable strings for the dashboard.
  """

  alias SymphonyElixir.Config

  @callback humanize_method(method :: String.t(), payload :: map()) :: String.t()

  @spec adapter() :: module()
  def adapter do
    case Config.agent_kind() do
      "codex" -> SymphonyElixir.Codex.EventHumanizer
      _ -> SymphonyElixir.Claude.EventHumanizer
    end
  end

  @spec humanize_method(String.t(), map()) :: String.t()
  def humanize_method(method, payload), do: adapter().humanize_method(method, payload)
end
