defmodule Aiur.Orchestrator.CapacityStarvation.Alert do
  @moduledoc false

  alias Aiur.Alerts
  alias Aiur.Orchestrator.{DispatchPolicy, Slots}

  @alert_topic "fleet.capacity.starved"
  @resolved_topic "fleet.capacity.starved.resolved"

  @spec open(map(), map(), pos_integer(), keyword()) :: term()
  def open(snapshot, detector, debounce_cycles, opts) do
    {binding_key, binding_explanation} = binding_constraint(snapshot, detector)
    details = alert_details(snapshot, binding_key, debounce_cycles)
    message = alert_message(snapshot, binding_key, binding_explanation)

    alert_opts = [
      reason: message,
      needs_attention: true,
      severity: "warning",
      details: details,
      require_persistence: true
    ]

    emit(@alert_topic, message, alert_opts, opts)
  end

  @spec resolve(keyword()) :: term()
  def resolve(opts) do
    message = "Fleet capacity starvation cleared."

    alert_opts = [
      reason: message,
      needs_attention: false,
      severity: "info",
      require_persistence: true
    ]

    emit(@resolved_topic, message, alert_opts, opts)
  end

  defp emit(topic, message, alert_opts, opts) do
    case Keyword.get(opts, :alert_fun) do
      alert_fun when is_function(alert_fun, 2) -> alert_fun.(topic, alert_opts)
      _ -> Alerts.emit_system(topic, message, alert_opts)
    end
  end

  defp binding_constraint(%{prewarm_hold?: true}, _detector),
    do: {"prewarm_hold", "prewarm hold"}

  defp binding_constraint(%{admission_constraint: constraint}, _detector)
       when is_atom(constraint) and not is_nil(constraint) do
    {Atom.to_string(constraint), admission_constraint_label(constraint)}
  end

  defp binding_constraint(%{configured_cap: cap, occupied_slots: occupied}, _detector)
       when cap <= occupied,
       do: {"config_ceiling", "configured concurrency ceiling (cap #{cap})"}

  defp binding_constraint(%{authorized: authorized} = snapshot, detector) when authorized != [] do
    cond do
      all_ready_states_saturated?(authorized, snapshot) ->
        {"config_ceiling", "per-state concurrency ceiling"}

      not Slots.worker_slots_available?(snapshot.state) ->
        {"worker_capacity", "worker-host capacity"}

      snapshot.effective_cap <= snapshot.occupied_slots ->
        {"effective_envelope", "effective envelope (cap #{snapshot.effective_cap} static)"}

      detector.provisioning_lag? ->
        {"provisioning_rate", "provisioning rate (capacity rose without live-agent growth)"}

      true ->
        {"none", "no binding constraint identified"}
    end
  end

  defp binding_constraint(%{authorization_denials: denials}, _detector) when denials > 0,
    do: {"dispatch_authorization_denials", "dispatch authorization denials (#{denials})"}

  defp binding_constraint(_snapshot, _detector), do: {"none", "no binding constraint identified"}

  defp all_ready_states_saturated?(authorized, snapshot) do
    authorized
    |> Enum.uniq_by(& &1.state)
    |> Enum.all?(&(not DispatchPolicy.state_slots_available?(&1, snapshot.state)))
  end

  defp admission_constraint_label(:memory_floor), do: "free-memory admission floor"
  defp admission_constraint_label(:file_descriptor_headroom), do: "file-descriptor headroom"
  defp admission_constraint_label(:hard_load_gate), do: "hard load gate"
  defp admission_constraint_label(other), do: other |> Atom.to_string() |> String.replace("_", " ")

  defp alert_message(snapshot, binding_key, binding_explanation) do
    "Fleet capacity starved: #{snapshot.ready_count} ready, #{snapshot.live_agents} live, " <>
      "load #{format_number(snapshot.load)} on #{snapshot.schedulers} schedulers " <>
      "(target #{format_number(snapshot.target * snapshot.schedulers)}), " <>
      "cap #{snapshot.effective_cap}; #{constraint_summary(binding_key, binding_explanation)}."
  end

  defp constraint_summary("none", explanation), do: explanation
  defp constraint_summary(_binding_key, explanation), do: "binding constraint: #{explanation}"

  defp alert_details(snapshot, binding_key, debounce_cycles) do
    %{
      "ready_count" => snapshot.ready_count,
      "live_agents" => snapshot.live_agents,
      "load_average" => snapshot.load,
      "schedulers" => snapshot.schedulers,
      "target_load" => snapshot.target * snapshot.schedulers,
      "configured_cap" => snapshot.configured_cap,
      "effective_cap" => snapshot.effective_cap,
      "authorization_denials" => snapshot.authorization_denials,
      "binding_constraint" => binding_key,
      "debounce_cycles" => debounce_cycles
    }
  end

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
end
