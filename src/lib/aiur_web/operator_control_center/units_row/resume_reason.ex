defmodule AiurWeb.OperatorControlCenter.UnitsRow.ResumeReason do
  @moduledoc false

  alias AiurWeb.OperatorControlCenter.UnitsRow.Value

  @spec project(map() | term(), term()) :: map() | nil
  def project(status_row, pause) do
    latest = latest_control(status_row)
    control_status = Value.get(status_row, :work_state)

    with true <- control_status in [:paused, :sleeping],
         :resume <- Value.get(latest, :action) do
      case Value.get(latest, :status) do
        :rejected -> outcome(:declined, control_status, pause, Value.get(latest, :rejection))
        :expired -> outcome(:dropped, control_status, pause, Value.get(latest, :expiry))
        _status -> nil
      end
    else
      _other -> nil
    end
  end

  defp outcome(outcome, control_status, pause, detail) do
    condition = Value.get(detail, :condition) || %{}

    %{
      outcome: outcome,
      control_status: Value.get(condition, :control_status) || control_status,
      pause_reason: Value.get(condition, :pause_reason) || pause,
      current_pause_reason: pause,
      detail: detail
    }
  end

  defp latest_control(status_row) do
    control = Value.get(status_row, :control) || Value.get(status_row, :capabilities) || %{}
    Value.get(control, :latest_resume_control) || Value.get(control, :latest_control)
  end
end
