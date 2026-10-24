defmodule AiurWeb.Build.TicketControl do
  @moduledoc "Truthful modal control; the conversation destination stays nil until C14-T03."
  alias AiurWeb.OperatorControlCenter.UnitsControlPolicy, as: Policy

  @spec encode(map() | nil, map() | nil, boolean()) :: map()
  def encode(nil, _control, _writable), do: %{control: nil, chat: nil}

  def encode(row, control, writable) do
    affordance = Policy.affordance(row, control)
    status = if control, do: status(control)
    action = affordance.action || affordance.pending_action
    title = title(affordance, status, writable)
    %{control: %{action: action, state: if(writable, do: affordance.state, else: :disabled), title: title, status: status}, chat: nil}
  end

  defp status(control) do
    presentation = Policy.presentation(control)
    %{label: presentation.label, tone: presentation.tone, retry: presentation.retry?}
  end

  defp title(_affordance, _status, false), do: "Dashboard is read-only"
  defp title(%{state: :disabled, reason: reason}, _status, true), do: Policy.disabled_reason(reason)
  defp title(_affordance, %{tone: tone, label: label}, true) when tone in [:pending, :error, :warning], do: label
  defp title(%{action: :resume}, _status, true), do: "Resume agent"
  defp title(_affordance, _status, true), do: "Pause agent"
end
