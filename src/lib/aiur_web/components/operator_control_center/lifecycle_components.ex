defmodule AiurWeb.OperatorControlCenter.LifecycleComponents do
  @moduledoc false

  use Phoenix.Component

  @steps [:recorded, :dispatch_pending, :delivered, :acknowledged, :resolved]
  @lifecycles @steps ++ [:delivery_failed, :superseded]
  @labels %{
    recorded: "Recorded",
    dispatch_pending: "Dispatch pending",
    delivered: "Delivered",
    acknowledged: "Acknowledged",
    resolved: "Resolved",
    delivery_failed: "Delivery failed",
    superseded: "Superseded"
  }

  attr(:lifecycle, :any, required: true)

  def lifecycle_chip(assigns) do
    lifecycle = normalize(assigns.lifecycle)
    assigns = assign(assigns, lifecycle: lifecycle, label: chip_label(lifecycle), tone: tone(lifecycle))

    ~H"""
    <span class={["chip", @tone]}><span class="chip-dot"></span>{@label}</span>
    """
  end

  attr(:lifecycle, :any, required: true)

  def lifecycle_stepper(assigns) do
    lifecycle = normalize(assigns.lifecycle)

    if lifecycle == :superseded do
      assigns = assign(assigns, :lifecycle, lifecycle)

      ~H"""
      <p class="lifecycle-standalone superseded">↻ Superseded — replaced by a newer decision</p>
      """
    else
      entries = Enum.map(@steps, &step_entry(&1, lifecycle))
      assigns = assign(assigns, entries: entries, failed: lifecycle == :delivery_failed)

      ~H"""
      <div class={["lifecycle", @failed && "failed"]} aria-label={"Decision lifecycle: #{label(@lifecycle)}"}>
        <div :for={{entry, index} <- Enum.with_index(@entries)} class={["lifecycle-step", entry.state]}>
          <span :if={index > 0} class="lifecycle-connector"></span>
          <span class={["lifecycle-node", entry.failed && "failed"]}>
            <span class="lifecycle-dot"></span>{entry.label}
          </span>
        </div>
      </div>
      """
    end
  end

  def label(lifecycle), do: Map.get(@labels, normalize(lifecycle), humanize(lifecycle))

  defp step_entry(step, lifecycle) do
    effective = if lifecycle == :delivery_failed, do: :delivered, else: lifecycle
    current_index = Enum.find_index(@steps, &(&1 == effective)) || 0
    step_index = Enum.find_index(@steps, &(&1 == step)) || 0

    %{
      label: if(lifecycle == :delivery_failed and step == :delivered, do: "Delivery failed", else: label(step)),
      state:
        cond do
          step_index < current_index -> "done"
          step_index == current_index -> "current"
          true -> "pending"
        end,
      failed: lifecycle == :delivery_failed and step == :delivered
    }
  end

  defp chip_label(:recorded), do: "Recorded · open"
  defp chip_label(:delivered), do: "Delivered · awaiting ack"
  defp chip_label(lifecycle), do: label(lifecycle)

  defp tone(lifecycle) when lifecycle in [:delivery_failed], do: "blocking"
  defp tone(lifecycle) when lifecycle in [:resolved], do: "good"
  defp tone(lifecycle) when lifecycle in [:delivered, :acknowledged], do: "accent"
  defp tone(lifecycle) when lifecycle in [:superseded], do: "super"
  defp tone(_lifecycle), do: "attention"

  defp normalize(lifecycle) when lifecycle in @lifecycles, do: lifecycle

  defp normalize(lifecycle) when is_binary(lifecycle) do
    Enum.find(@lifecycles, :recorded, &(Atom.to_string(&1) == lifecycle))
  end

  defp normalize(_lifecycle), do: :recorded
  defp humanize(nil), do: "Unknown"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
