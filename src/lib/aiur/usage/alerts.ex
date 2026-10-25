defmodule Aiur.Usage.Alerts do
  @moduledoc "Emits one low-usage alert per configured provider episode."
  use GenServer

  alias Aiur.{Alerts, ProviderMeters.Events}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    _ = Events.subscribe_observed()

    {:ok,
     %{
       active: MapSet.new(),
       emit: Keyword.get(opts, :emit, &Alerts.emit_system/2),
       thresholds: Keyword.get(opts, :thresholds, &configured_threshold/1)
     }}
  end

  @doc false
  @spec evaluate(atom(), number(), number(), MapSet.t(), (String.t(), keyword() -> term())) :: MapSet.t()
  def evaluate(provider, remaining, threshold, state, emit) when is_number(remaining) and is_number(threshold) do
    transition(provider, remaining <= threshold, remaining, threshold, state, emit)
  end

  @impl true
  def handle_info({:provider_meter_changed, %{provider: provider, windows: windows, freshness: freshness}}, state) do
    threshold = threshold_for(state.thresholds, provider)
    remaining = remaining_percent(windows)

    active =
      if is_number(threshold) and freshness in [:fresh, :partial] and is_number(remaining),
        do: evaluate(provider, remaining, threshold, state.active, state.emit),
        else: state.active

    {:noreply, %{state | active: active}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp threshold_for(thresholds, provider) when is_function(thresholds, 1), do: thresholds.(provider)
  defp threshold_for(thresholds, provider) when is_map(thresholds), do: Map.get(thresholds, provider) || Map.get(thresholds, Atom.to_string(provider))
  defp threshold_for(_thresholds, _provider), do: nil

  defp transition(provider, true, remaining, threshold, state, emit) do
    if MapSet.member?(state, provider) do
      state
    else
      emit_transition(provider, :low, remaining, threshold, state, emit)
    end
  end

  defp transition(provider, false, remaining, _threshold, state, emit) do
    if MapSet.member?(state, provider), do: emit_transition(provider, :resolved, remaining, nil, state, emit), else: state
  end

  defp emit_transition(provider, :low, remaining, threshold, state, emit) do
    emit_and_update("system.usage.#{provider}.low", "#{provider} usage is at #{Float.round(remaining / 1, 1)}% remaining (threshold #{threshold}%).", provider, state, emit, :put)
  end

  defp emit_transition(provider, :resolved, remaining, _threshold, state, emit) do
    emit_and_update("system.usage.#{provider}.resolved", "#{provider} usage recovered to #{Float.round(remaining / 1, 1)}% remaining.", provider, state, emit, :delete)
  end

  defp emit_and_update(topic, message, provider, state, emit, operation) do
    case emit.(topic, message: message, needs_attention: false, severity: if(operation == :put, do: "warning", else: "info")) do
      :ok -> update_active(state, provider, operation)
      _error -> state
    end
  end

  defp update_active(state, provider, :put), do: MapSet.put(state, provider)
  defp update_active(state, provider, :delete), do: MapSet.delete(state, provider)

  defp configured_threshold(provider) do
    with {:ok, settings} <- Aiur.Config.settings(),
         config when is_map(config) <- settings.usage.alerts,
         value when is_map(value) <- Map.get(config, provider) || Map.get(config, Atom.to_string(provider)),
         threshold when is_number(threshold) <- Map.get(value, :threshold) || Map.get(value, "threshold") do
      threshold
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp remaining_percent(windows) when is_map(windows) do
    used =
      windows
      |> Map.values()
      |> Enum.map(&Map.get(&1, :used_percent))
      |> Enum.filter(&is_number/1)

    if used == [], do: nil, else: 100 - Enum.max(used)
  end

  defp remaining_percent(_windows), do: nil
end
