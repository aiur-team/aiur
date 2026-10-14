defmodule Aiur.Events.HistoryStore do
  @moduledoc """
  Write sink for per-ticket event markers.

  The implementation is configured under `config :aiur, Aiur.Events.HistoryStore`.
  An absent setting or `:none` disables writes. Implementations must not raise
  or block; readers remain owned by the backing history implementation.
  """

  @type kind :: :emit | :emit_alert | :consumed | :self
  @callback record(identifier :: String.t(), kind :: kind(), event :: map()) :: :ok

  @spec record(String.t(), kind(), map()) :: :ok
  def record(identifier, kind, event) do
    case Application.get_env(:aiur, __MODULE__, :none) do
      :none -> :ok
      module -> module.record(identifier, kind, event)
    end
  end
end
