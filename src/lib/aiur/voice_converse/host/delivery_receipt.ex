defmodule Aiur.VoiceConverse.Host.DeliveryReceipt do
  @moduledoc false

  @spec status(term()) :: :accepted | :delivered | :failed | :unknown
  def status({:ok, %{receipt: receipt}}) when receipt in [:accepted, :held_async], do: :accepted
  def status({:ok, %{receipt: receipt}}) when receipt in [:harness_queued, :in_context, :read], do: :delivered
  def status({:ok, %{receipt: receipt}}) when receipt in [:failed, :superseded], do: :failed
  def status(_result), do: :unknown

  @spec send_error(term()) :: :failed | :unknown
  def send_error({:outcome_unknown, _details}), do: :unknown
  def send_error({:not_queued, :timeout}), do: :failed
  def send_error({:message_id_conflict, _id}), do: :failed
  def send_error(reason) when reason in [:invalid_message, :no_running_agent, :unavailable, :listener_mode_unavailable], do: :failed
  def send_error(_reason), do: :unknown
end
