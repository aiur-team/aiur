defmodule Aiur.Application.ExportChildren do
  @moduledoc false

  @spec child_specs(boolean()) :: [Supervisor.child_spec() | {module(), keyword()}]
  @spec child_specs(boolean(), keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def child_specs(enabled, opts \\ [])
  def child_specs(false, _opts), do: []

  def child_specs(true, opts) do
    exporter =
      {Aiur.Events.Export.Exporter,
       on_unavailable: fn reason ->
         Aiur.Signal.alert("system.events.export_unavailable", reason: inspect(reason), needs_attention: true, severity: "warning")
       end,
       on_appended: fn head, epoch ->
         Phoenix.PubSub.broadcast(Aiur.PubSub, "events:export", {:export_appended, head, epoch})
       end}

    delivery =
      if Keyword.get_lazy(opts, :webhook_enabled?, &Aiur.Config.events_export_webhook_enabled?/0),
        do: [{Aiur.Events.Outbound.Delivery, alert_fun: &Aiur.Alerts.emit_system/2}],
        else: []

    [exporter | delivery]
  end
end
