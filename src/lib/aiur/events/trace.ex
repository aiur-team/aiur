defmodule Aiur.Events.Trace do
  # aiur:event-bus-boundary-member

  @moduledoc """
  Optional, best-effort event-bus trace sink. The application config selects
  an implementation; absent configuration or `:none` disables tracing.
  """

  @callback trace(kind :: :publish | :receive, topic :: String.t(), opts :: keyword()) :: :ok

  @spec trace(:publish | :receive, String.t(), keyword()) :: :ok
  def trace(kind, topic, opts) do
    case Application.get_env(:aiur, __MODULE__, :none) do
      :none -> :ok
      module -> module.trace(kind, topic, opts)
    end
  rescue
    _ -> :ok
  end
end
