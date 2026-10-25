defmodule Aiur.Orchestrator.ControlLifecycle.Validation do
  @moduledoc false

  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.TrackerIdentity

  @spec validate_request(map()) :: :ok | {:error, map()}
  def validate_request(attrs) do
    attrs
    |> request_validations()
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  defp request_validations(attrs) do
    [
      validate_request_id(attrs),
      validate_issue_id(attrs),
      validate_tracker_identity(attrs),
      validate_action(attrs),
      validate_generation(attrs),
      validate_expected_status(attrs),
      validate_expected_version(attrs),
      validate_requester(attrs)
    ]
  end

  defp validate_request_id(attrs) do
    if valid_request_id?(Map.get(attrs, :request_id)),
      do: :ok,
      else: {:error, rejection(:control_failed, "request ID must be a non-empty string or positive integer")}
  end

  defp validate_issue_id(attrs) do
    if valid_issue_id?(Map.get(attrs, :issue_id)),
      do: :ok,
      else: {:error, rejection(:not_found, "unit identifier is required")}
  end

  defp validate_tracker_identity(attrs) do
    if TrackerIdentity.joinable?(Map.get(attrs, :tracker_identity)),
      do: :ok,
      else: {:error, rejection(:not_eligible, "unit does not have a joinable repository-qualified identity")}
  end

  defp validate_action(attrs) do
    if Map.get(attrs, :action) in ControlLifecycle.allowed_values(:actions),
      do: :ok,
      else: {:error, rejection(:unsupported, "control action must be pause or resume")}
  end

  defp validate_generation(attrs) do
    if valid_generation?(Map.get(attrs, :generation)),
      do: :ok,
      else: {:error, rejection(:stale_generation, "worker generation is required")}
  end

  defp validate_expected_status(attrs) do
    if is_atom(Map.get(attrs, :expected_status)),
      do: :ok,
      else: {:error, rejection(:control_failed, "expected authoritative status is required")}
  end

  defp validate_expected_version(attrs) do
    if valid_expected_version?(Map.get(attrs, :expected_version)),
      do: :ok,
      else: {:error, rejection(:control_failed, "expected authoritative version must be a non-negative integer")}
  end

  defp validate_requester(attrs) do
    if Map.get(attrs, :requester) in ControlLifecycle.allowed_values(:requesters),
      do: :ok,
      else: {:error, rejection(:control_failed, "requester class is required")}
  end

  @spec valid_request_id?(term()) :: boolean()
  def valid_request_id?(value), do: (is_binary(value) and value != "") or (is_integer(value) and value > 0)
  @spec valid_issue_id?(term()) :: boolean()
  def valid_issue_id?(value), do: not is_nil(value)
  @spec valid_generation?(term()) :: boolean()
  def valid_generation?(value), do: (is_binary(value) and value != "") or (is_integer(value) and value >= 0)
  @spec valid_expected_version?(term()) :: boolean()
  def valid_expected_version?(value), do: is_integer(value) and value >= 0

  @spec rejection(atom(), String.t()) :: map()
  def rejection(class, message), do: %{class: class, message: message}

  @spec rejection(atom(), String.t(), keyword()) :: map()
  def rejection(class, message, opts) do
    case Keyword.get(opts, :condition) do
      %{control_status: control_status, pause_reason: pause_reason}
      when is_atom(control_status) and (is_atom(pause_reason) or is_nil(pause_reason)) ->
        %{class: class, message: message, condition: %{control_status: control_status, pause_reason: pause_reason}}

      _condition ->
        rejection(class, message)
    end
  end

  @spec rejection_message(atom()) :: String.t()
  def rejection_message(:not_found), do: "target unit was not found"
  def rejection_message(:not_eligible), do: "target unit is not eligible for control"
  def rejection_message(:unsupported), do: "target worker does not support this control"
  def rejection_message(:stale_generation), do: "target worker generation is no longer current"
  def rejection_message(:worker_unavailable), do: "target worker is unavailable"
  def rejection_message(:already_in_state), do: "target is already in the requested state"
  def rejection_message(:control_failed), do: "control routing failed"
  def rejection_message(:pause_release_failed), do: "worker could not release the active pause containment"
  def rejection_message(:superseded), do: "a newer control intent superseded this request"
end
