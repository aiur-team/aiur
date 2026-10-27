defmodule Aiur.Listener.Scheduler do
  @moduledoc "Resolves conversation delivery while keeping listener routing dark by default."

  require Logger
  alias Aiur.AgentQueue
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy

  @type origin :: :agent_chat | :http | :tui | :internal

  @spec routing() :: :legacy | :listener
  def routing, do: routing([])

  @doc false
  @spec routing(keyword()) :: :legacy | :listener
  def routing(opts) do
    flag = Application.get_env(:aiur, :listener_send_routing, :legacy)
    warn_invalid_flag(flag)
    if flag == :listener and Keyword.get_lazy(opts, :spec_status, &spec_status/0) == :ok, do: :listener, else: :legacy
  end

  @spec spec_status() :: term()
  def spec_status do
    module = Module.concat(["Aiur", "Listener", "Spec"])
    if Code.ensure_loaded?(module), do: module.status(), else: {:error, :not_installed}
  end

  @spec resolve(origin(), map() | nil, map(), atom() | nil) :: {:ok, keyword()} | {:error, atom()}
  def resolve(origin, view, capabilities, fallback), do: resolve(origin, view, capabilities, fallback, [])

  @doc false
  @spec resolve(origin(), map() | nil, map(), atom() | nil, keyword()) :: {:ok, keyword()} | {:error, atom()}
  def resolve(origin, view, capabilities, _fallback, opts) do
    case routing(opts) do
      :legacy -> legacy(origin, capabilities)
      :listener -> listener(view)
    end
  end

  @spec restamp_fun(map()) :: (map() -> map())
  def restamp_fun(view) do
    fn delivery ->
      case listener(view) do
        {:ok, opts} -> Map.merge(delivery, AgentQueue.operator_message("", "", opts).delivery)
        {:error, _} -> delivery
      end
    end
  end

  defp listener(%{effective: :sync}), do: {:ok, [delivery_policy: :checkpoint, listener_mode: :sync]}
  defp listener(%{effective: :async}), do: {:ok, [listener_mode: :async]}

  defp listener(%{effective: :steer, support: %{steer: %{carrier: :emulated_interrupt}}}),
    do: {:ok, [delivery_policy: :interrupt, fallback: :queue_next, listener_mode: :steer, steer_carrier: :emulated_interrupt]}

  defp listener(_view), do: {:error, :listener_mode_unavailable}

  defp legacy(:agent_chat, caps), do: DeliveryPolicy.normalize_delivery_request(:interrupt, :queue_next, caps)
  defp legacy(:http, caps), do: DeliveryPolicy.normalize_delivery_request(:checkpoint, nil, caps)
  defp legacy(:tui, caps), do: DeliveryPolicy.normalize_delivery_request(:auto, nil, caps)
  defp legacy(_origin, _caps), do: {:error, :invalid_message}

  defp warn_invalid_flag(flag) when flag in [:legacy, :listener], do: :ok

  defp warn_invalid_flag(_flag) do
    key = {__MODULE__, :invalid_flag_warned}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      Logger.warning("Invalid listener_send_routing; using legacy routing")
    end
  end
end
