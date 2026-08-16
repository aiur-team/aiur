defmodule Aiur.ExecutorListener do
  @moduledoc """
  Daemon-resident, supervised consumer of `executor.#` events for an Executor
  run.

  Started only when the run launches with `--executor` (see
  `Aiur.CLI.maybe_set_executor/1` and `Aiur.Application.child_specs/1`), so an
  ordinary non-Executor launch does not silently acquire a Command inbox it
  will never read — Commands consumed by something that cannot act on them
  would be a worse failure than the current one.

  ## Why the daemon owns the subscription

  The earlier design relied on the Executor starting `aiur executor-listen` in
  a background shell. That shell is bounded by whatever process limits the
  Executor harness imposes (observed: a 600-second per-command cap), so even a
  correctly-started listener died every ten minutes with nothing announcing the
  exit, and a dead listener was indistinguishable from a quiet one. This process
  is supervised by the run itself: the supervisor restarts it, it re-establishes
  its Exchange binding when the binding is lost, and it replays missed journal
  events from its own durable watermark so a restart never re-notifies for
  events it already delivered.

  ## Delivery

  For every `executor.decision.requested` / `executor.decision.deferred` event
  this process emits a needs-attention alert (`executor.command.requested` /
  `executor.command.deferred`) naming the decision and its ticket, so the
  Executor's monitoring (`aiur watch`, `aiur alerts --needs-attention`) surfaces
  the Command even when no interactive `executor-listen` stream is running. The
  Executor reads the Command's full payload through `aiur commands
  <decision-id>` and answers with `executor-answer` / `executor-escalate`. The
  `executor-listen` CLI remains available as an optional raw JSON-line stream;
  it keeps its own replay cursor, so it does not collide with this process's
  watermark.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, Config.Paths, Events.Exchange, Events.Topic, ExecutorEvents, JsonStore}

  @default_topic "executor.#"
  @command_topics ~w(executor.decision.requested executor.decision.deferred)
  @resubscribe_interval_ms 30_000

  @type state :: %{
          topic: String.t(),
          subscribed?: boolean(),
          watermark: non_neg_integer() | nil,
          resubscribe_interval_ms: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  True only while the daemon-resident listener is currently subscribed to
  `executor.#` on the Exchange. A process that exists but lost its binding
  (Exchange restart) reports false, so `aiur status` never mistakes "was
  started once" for "is listening now".
  """
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server \\ __MODULE__) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        try do
          Exchange.bindings_for(pid) |> Enum.member?(@default_topic)
        rescue
          _error -> false
        catch
          :exit, _reason -> false
        end

      _not_registered ->
        false
    end
  end

  @impl true
  def init(opts) do
    topic = Keyword.get(opts, :topic, @default_topic)
    interval = Keyword.get(opts, :resubscribe_interval_ms, @resubscribe_interval_ms)
    watermark = read_watermark()
    subscribed? = subscribe_or_arm(topic)

    if subscribed? do
      replay_and_deliver(topic, watermark)
    end

    schedule_resubscribe(interval)
    {:ok, %{topic: topic, subscribed?: subscribed?, watermark: watermark, resubscribe_interval_ms: interval}}
  end

  @impl true
  def handle_info({:event, event}, %{subscribed?: true} = state) do
    process_event(event, state)
    {:noreply, state}
  end

  # The Exchange is a sibling that can be restarted by the supervisor. When it
  # comes back its binding table is fresh, so this listener's binding is gone
  # even though the process is alive. Re-establish it and replay anything
  # published while it was not listening — the durable watermark makes that
  # replay safe (no double delivery), and `alive?/0` reflects the gap truthfully
  # until the binding is restored.
  def handle_info(:resubscribe, %{topic: topic, resubscribe_interval_ms: interval} = state) do
    state =
      case subscribe_or_arm(topic) do
        true ->
          if not state.subscribed? do
            replay_and_deliver(topic, state.watermark)
          end

          %{state | subscribed?: true}

        false ->
          state
      end

    schedule_resubscribe(interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{topic: topic}) do
    Exchange.unsubscribe(topic)
    :ok
  rescue
    _error -> :ok
  end

  defp subscribe_or_arm(topic) do
    if bound?(topic) do
      # Already bound — re-subscribing would add a second row to the Exchange's
      # duplicate-bag table and deliver every event twice. Only (re)subscribe
      # when the binding is actually gone (Exchange restart / first start).
      true
    else
      case Exchange.subscribe(topic) do
        :ok ->
          true

        {:error, reason} ->
          Logger.error("aiur_executor_listener phase=subscribe_failed topic=#{topic} reason=#{inspect(reason)}")
          report_unavailable()
          false
      end
    end
  rescue
    error ->
      Logger.error("aiur_executor_listener phase=subscribe_error topic=#{topic} error=#{Exception.message(error)}")
      report_unavailable()
      false
  catch
    :exit, reason ->
      Logger.error("aiur_executor_listener phase=subscribe_exit topic=#{topic} reason=#{inspect(reason)}")
      report_unavailable()
      false
  end

  defp bound?(topic) do
    try do
      Exchange.bindings_for(self()) |> Enum.member?(topic)
    rescue
      _error -> false
    catch
      :exit, _reason -> false
    end
  end

  # Best-effort, guarded: at boot the alert pipeline may not be ready yet, and a
  # failure to say "I could not subscribe" must not itself take the listener
  # down. `alive?/0` and the status line remain the authoritative signal.
  defp report_unavailable do
    if alerting_enabled?() do
      Alerts.emit_custom(
        "executor.listener.unavailable",
        "The Executor event listener could not subscribe to executor.#; Commands will not reach the Executor.",
        reason: "executor listener subscription failed",
        needs_attention: true,
        severity: "warning"
      )
    end
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp replay_and_deliver(topic, watermark) do
    case ExecutorEvents.replay([topic], watermark) do
      {:ok, events} ->
        Enum.each(events, &process_event(&1, %{topic: topic, subscribed?: true, watermark: watermark, resubscribe_interval_ms: 0}))

      {:error, reason} ->
        Logger.error("aiur_executor_listener phase=replay_failed reason=#{inspect(reason)}")
    end
  end

  defp process_event(event, state) do
    if matching_fresh_event?(event, state) do
      try do
        deliver(event)
        advance_watermark(event_id(event))
      rescue
        error -> log_delivery_failure(event, error)
      catch
        kind, reason -> log_delivery_failure(event, {kind, reason})
      end
    end

    state
  end

  defp matching_fresh_event?(event, %{topic: pattern, watermark: watermark}) do
    case {event_topic(event), event_id(event)} do
      {event_topic, id} when is_binary(event_topic) and is_integer(id) ->
        Topic.matches?(pattern, event_topic) and id > (watermark || 0)

      _not_a_topic_or_id ->
        false
    end
  end

  defp deliver(event) do
    scrubbed = ExecutorEvents.scrub_untrusted_output(event)

    if command_topic?(scrubbed) and alerting_enabled?() do
      emit_command_alert(scrubbed)
    end

    :ok
  end

  defp emit_command_alert(event) do
    decision_id = Map.get(event, "decision_id") || Map.get(event, :decision_id)
    issue = Map.get(event, "issue_identifier") || Map.get(event, :issue_identifier)
    kind = if event_topic(event) == "executor.decision.deferred", do: "deferred", else: "requested"
    title = Map.get(event, "title") || Map.get(event, :title)

    message =
      "Executor Command #{decision_id} awaits you (ticket ##{issue})" <>
        if is_binary(title) and title != "", do: ": #{truncate(title, 80)}", else: ""

    # The alert pipeline (ledger, event-log, sound) is best-effort delivery and
    # runs outside the durable journal. A failure anywhere in it must never
    # block this listener from advancing its watermark — the event was consumed
    # either way, and a re-delivery would only duplicate the notification.
    Alerts.emit_custom(
      "executor.command.#{kind}",
      message,
      issue: issue,
      reason: "executor.decision.#{kind} for decision #{decision_id} (ticket ##{issue})",
      needs_attention: true,
      severity: "warning"
    )
  rescue
    error ->
      Logger.error("aiur_executor_listener phase=alert_failed topic=#{event_topic(event)} error=#{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.error("aiur_executor_listener phase=alert_exit topic=#{event_topic(event)} reason=#{inspect(reason)}")
      :ok
  end

  defp command_topic?(event), do: event_topic(event) in @command_topics

  defp event_topic(event), do: Map.get(event, :topic) || Map.get(event, "topic")
  defp event_id(event), do: Map.get(event, :id) || Map.get(event, "id")

  defp alerting_enabled?, do: Application.get_env(:aiur, :executor_listener_alerting?, true)

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp truncate(_text, _max), do: ""

  defp schedule_resubscribe(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :resubscribe, interval)
    :ok
  end

  defp read_watermark do
    case JsonStore.read(watermark_path()) do
      {:ok, %{"last_seen_event_id" => id}} when is_integer(id) and id > 0 -> id
      {:ok, %{last_seen_event_id: id}} when is_integer(id) and id > 0 -> id
      _other -> 0
    end
  end

  defp advance_watermark(id) do
    JsonStore.write!(watermark_path(), %{"last_seen_event_id" => id})
    :ok
  end

  defp watermark_path,
    do: Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.listener.watermark.json")

  defp log_delivery_failure(event, error) do
    Logger.error("aiur_executor_listener phase=delivery_failed topic=#{inspect(event_topic(event))} id=#{inspect(event_id(event))} error=#{inspect(error)}")
  end
end
