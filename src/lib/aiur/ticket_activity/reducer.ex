defmodule Aiur.TicketActivity.Reducer do
  @moduledoc false

  @spec accept_progress?(:checkin | :phase, integer(), integer(), boolean()) :: boolean()
  def accept_progress?(:checkin, _percent, _current_percent, _provenance_changed?), do: true
  def accept_progress?(:phase, _percent, _current_percent, true), do: true
  def accept_progress?(:phase, percent, current_percent, false), do: percent >= current_percent

  @spec transition_stage(atom() | nil, atom(), :start | :end) :: {:set, atom()} | :clear | :keep
  def transition_stage(_current, phase, :start), do: {:set, phase}
  def transition_stage(phase, phase, :end), do: :clear
  def transition_stage(_current, _phase, :end), do: :keep
end
