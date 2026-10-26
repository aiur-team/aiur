defmodule Aiur.Events.Outbound.Delivery do
  @moduledoc "Supervises at-least-once signed webhook delivery from the export journal."
  # aiur:event-bus-boundary-member

  alias Aiur.Config.{Paths, WebhookDestination}
  alias Aiur.Events.DurableConsumer
  alias Aiur.Events.Outbound.{ExportJournal, Webhook}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    export = Keyword.get_lazy(opts, :export, &Aiur.Config.events_export/0)

    with {:ok, cursor_path} <- cursor_path(opts) do
      handler =
        Webhook.new!(
          url: Keyword.get(opts, :url, export.webhook_url),
          secret: Keyword.get_lazy(opts, :secret, fn -> System.fetch_env!("AIUR_OUTBOUND_WEBHOOK_SECRET") end),
          subject_id: Keyword.get(opts, :subject_id, export.subject_id),
          allow_private_destinations: Keyword.get(opts, :allow_private_destinations, Map.get(export, :allow_private_destinations, false)),
          request_timeout_ms: Keyword.get(opts, :request_timeout_ms, export.request_timeout_ms),
          request_fun: Keyword.get(opts, :request_fun, &Req.post/1),
          resolve_fun: Keyword.get(opts, :resolve_fun, &WebhookDestination.resolve/2),
          alert_fun: Keyword.get(opts, :alert_fun, &ignore_alert/2),
          clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
        )

      DurableConsumer.start_link(
        name: Keyword.get(opts, :name, __MODULE__),
        source: Keyword.get(opts, :source, {ExportJournal, ExportJournal}),
        handler: {Webhook, handler},
        cursor_path: cursor_path,
        replay_batch: Keyword.get(opts, :replay_batch, 500),
        retry_ms: Keyword.get(opts, :retry_ms, export.retry_ms),
        retry_max_ms: Keyword.get(opts, :retry_max_ms, max(export.retry_ms, 60_000)),
        jitter_fun: Keyword.get(opts, :jitter_fun, &random_jitter/1),
        schedule_fun: Keyword.get(opts, :schedule_fun, &Process.send_after/3)
      )
    end
  end

  defp cursor_path(opts) do
    case Keyword.get(opts, :cursor_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> with {:ok, dir} <- Paths.outbound_events_state_dir(), do: {:ok, Path.join(dir, "delivery-cursor.json")}
    end
  end

  defp random_jitter(0), do: 0
  defp random_jitter(window), do: :rand.uniform(window + 1) - 1

  defp ignore_alert(_topic, _opts), do: :ok
end
