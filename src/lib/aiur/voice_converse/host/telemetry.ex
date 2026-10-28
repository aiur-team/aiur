defmodule Aiur.VoiceConverse.Host.Telemetry do
  @moduledoc "Bridges voice conversation telemetry to operator alerts."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :telemetry.detach(__MODULE__)

    case attach() do
      :ok -> {:ok, nil}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)

  @events [
    [:voice_converse, :provider_cleanup, :give_up],
    [:voice_converse, :cost_cap, :reached]
  ]

  @spec attach(term(), (String.t(), String.t(), keyword() -> term())) :: :ok | {:error, :already_exists}
  def attach(id \\ __MODULE__, alert_fun \\ &Aiur.Alerts.emit_custom/3) do
    :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, alert_fun)
  end

  @doc false
  @spec handle_event(list(atom()), map(), map(), (String.t(), String.t(), keyword() -> term())) :: term()
  def handle_event([:voice_converse, :provider_cleanup, :give_up], _measurements, _metadata, alert_fun) do
    alert_fun.("voice_conversation.provider_cleanup.give_up", "Voice provider cleanup gave up; provider data may remain.", needs_attention: true)
  end

  def handle_event([:voice_converse, :cost_cap, :reached], _measurements, _metadata, alert_fun) do
    alert_fun.("voice_conversation.cost_cap.reached", "Voice conversation daily limit reached.", needs_attention: true)
  end
end
