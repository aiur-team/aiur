defmodule Aiur.Application.ExportChildren do
  @moduledoc false

  @spec child_specs(boolean()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def child_specs(false), do: []

  def child_specs(true) do
    [
      {Aiur.Events.Export.Exporter,
       on_unavailable: fn reason ->
         Aiur.Signal.alert("system.events.export_unavailable", reason: inspect(reason), needs_attention: true, severity: "warning")
       end,
       on_backlog: fn
         :raised, %{len: len, threshold: threshold} ->
           Aiur.Signal.alert("system.events.export_backlog", reason: "Exporter mailbox #{len} exceeds #{threshold} on two checks", needs_attention: true, severity: "warning")

         :cleared, %{len: len, threshold: threshold} ->
           Aiur.Signal.alert("system.events.export_backlog.resolved", reason: "Exporter mailbox #{len} below half of #{threshold} on two checks", needs_attention: false, severity: "info")
       end,
       on_appended: fn head, epoch ->
         Phoenix.PubSub.broadcast(Aiur.PubSub, "events:export", {:export_appended, head, epoch})
       end}
    ]
  end
end
