defmodule Aiur.Codex.SessionRecovery do
  @moduledoc """
  Classifies Codex session failures that require a fresh app-server transport.

  The caller remains responsible for restoring any claimed queue item and
  ending the stale session. This module deliberately returns only a boolean:
  the provider-reported active turn id must never become a new interrupt
  target.
  """

  @active_turn_mismatch ~r/\Aexpected active turn id ([A-Za-z0-9_-]+) but found ([A-Za-z0-9_-]+)\z/

  @spec recoverable?(term()) :: boolean()
  def recoverable?(:port_closed), do: true
  def recoverable?({:port_exit, status}) when is_integer(status), do: true
  def recoverable?({:turn_start_failed, reason}), do: transport_loss?(reason)

  def recoverable?({:turn_interrupt_failed, reason}) do
    transport_loss?(reason) or active_turn_mismatch?(reason)
  end

  def recoverable?(_reason), do: false

  defp transport_loss?(:port_closed), do: true
  defp transport_loss?({:port_exit, status}) when is_integer(status), do: true

  defp transport_loss?({wrapper, reason})
       when wrapper in [:turn_start_failed, :turn_interrupt_failed],
       do: transport_loss?(reason)

  defp transport_loss?(_reason), do: false

  defp active_turn_mismatch?({wrapper, reason})
       when wrapper in [:turn_start_failed, :turn_interrupt_failed],
       do: active_turn_mismatch?(reason)

  defp active_turn_mismatch?(%{"code" => -32_600, "message" => message})
       when is_binary(message) do
    case Regex.run(@active_turn_mismatch, message, capture: :all_but_first) do
      [expected_turn_id, actual_turn_id] -> expected_turn_id != actual_turn_id
      _other -> false
    end
  end

  defp active_turn_mismatch?(_reason), do: false
end
