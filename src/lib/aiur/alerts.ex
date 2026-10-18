defmodule Aiur.Alerts do
  @moduledoc """
  Loads alert definitions, emits structured alert events, and optionally plays
  one configured sound clip.
  """

  require Logger

  alias Aiur.{AgentEventLog, AgentEvents, AgentPubSub, AlertFeed, AlertLedger, Issue}
  alias Aiur.Alerts.{Config, Sound}
  alias Aiur.Config.Paths
  alias Aiur.Events.{Publisher, Topic}
  alias Aiur.Signal

  @type definition :: %{
          message: String.t(),
          sound: [String.t()]
        }

  @doc """
  Returns the raw YAML-derived alert definitions as a map keyed by
  pattern string. Insertion order is not preserved; for matching, use
  `definition_for_topic/1` which sorts by specificity.
  """
  @spec definitions() :: %{optional(String.t()) => definition()}
  defdelegate definitions(), to: Config

  @doc """
  Returns the alert definition whose YAML pattern key matches `topic`
  via `Aiur.Events.Topic.matches?/2`. Walks patterns in specificity
  order (more literal segments → first); ties broken lexicographically.
  Returns `nil` if no pattern matches.
  """
  @spec definition_for_topic(String.t()) :: definition() | nil
  def definition_for_topic(topic) when is_binary(topic) do
    Enum.find_value(sorted_patterns(), fn {pattern, definition} ->
      if Topic.matches?(pattern, topic), do: definition
    end)
  end

  def definition_for_topic(_topic), do: nil

  defp sorted_patterns do
    definitions()
    |> Enum.to_list()
    |> Enum.sort_by(fn {pattern, _def} -> {-Topic.specificity_score(pattern), pattern} end)
  end

  @spec emit_system(String.t(), keyword()) :: :ok | {:error, term()}
  def emit_system(name, opts \\ []) when is_binary(name) do
    do_emit(name, Keyword.get(opts, :message), Keyword.put(opts, :event_source, :system))
  end

  @spec emit_custom(String.t(), String.t()) :: :ok | {:error, term()}
  def emit_custom(name, message) when is_binary(name) and is_binary(message) do
    emit_custom(name, message, [])
  end

  @spec emit_custom(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_custom(name, message, opts)
      when is_binary(name) and is_binary(message) do
    do_emit(name, message, Keyword.put_new(opts, :event_source, :agent))
  end

  def emit_custom(_name, _message, _opts), do: {:error, :invalid_alert}

  defp do_emit(topic, override_message, opts) do
    # Durable callers retain their latch until publication succeeds, even if the ledger already records a resolution.
    if not Keyword.get(opts, :durable, false) and repeat_resolution?(topic) do
      :ok
    else
      emit_alert(topic, override_message, opts)
    end
  end

  # Repeating `.resolved` while a condition stays clear reports a state as a transition and buries records an
  # Executor would act on. The check is against the durable ledger rather than
  # caller-held state, so an emitter that loses its in-memory latch — a restart,
  # a fresh CLI process — still cannot replay a transition that already landed.
  # Reads and writes use the same ledger options, so the gate checks the ledger the emit writes.
  # Fails open: an unreadable ledger must not swallow a real transition.
  defp repeat_resolution?(topic) do
    AlertFeed.duplicate_resolution?(topic)
  rescue
    _unavailable -> false
  end

  defp emit_alert(topic, override_message, opts) do
    config = definition_for_topic(topic)
    message = override_message || config_message(config)

    # Always publish through the Exchange — even when there's no matching
    # alert entry. Subscribers to the topic bus see every alert-emitted
    # event, regardless of whether the Executor-facing sound/badge fires.
    metadata = alert_metadata(message, opts)
    unless Keyword.get(opts, :durable, false), do: publish_to_exchange(topic, message, metadata, opts)

    with {:ok, message} <- Config.present_string(message, :missing_message) do
      settings = Config.settings()
      selected_sound = Sound.select_sound(topic, config, settings)

      payload = %{
        "event" => "alert",
        "name" => topic,
        "topic" => topic,
        "message" => message,
        "reason" => metadata.reason,
        "severity" => metadata.severity,
        "needs_attention" => metadata.needs_attention,
        "source_ticket_id" => metadata.source_ticket_id,
        "sound" => selected_sound
      }

      workspace = Keyword.get(opts, :workspace) || resolve_workspace(Keyword.get(opts, :issue))
      worker_host = Keyword.get(opts, :worker_host)

      Logger.info("[alert]#{identifier_suffix(opts)} #{topic}: #{message}")

      timestamp = DateTime.utc_now()

      alert_event = %{
        event: :alert,
        timestamp: timestamp,
        name: topic,
        topic: topic,
        message: message,
        reason: metadata.reason,
        severity: metadata.severity,
        needs_attention: metadata.needs_attention,
        source_ticket_id: metadata.source_ticket_id,
        sound: selected_sound,
        raw: Jason.encode!(payload)
      }

      with :ok <- persist_alert(alert_event, workspace, worker_host, opts),
           :ok <- publish_durable(topic, message, metadata, opts) do
        AgentEventLog.write(workspace, worker_host, alert_event)
        maybe_write_central_alert_feed_entry(alert_event, workspace, worker_host, opts)
        Sound.maybe_play_sound(selected_sound, settings, opts)
        broadcast_agent_alert(topic, message, metadata, selected_sound, opts)
        Signal.refresh()
        :ok
      end
    end
  end

  defp persist_alert(alert_event, workspace, worker_host, opts) do
    result = write_alert_ledger_entry(alert_event, workspace, worker_host)
    if Keyword.get(opts, :durable, false), do: result, else: :ok
  end

  defp publish_durable(topic, message, metadata, opts) do
    if Keyword.get(opts, :durable, false), do: publish_to_exchange(topic, message, metadata, opts), else: :ok
  end

  defp alert_metadata(message, opts) do
    needs_attention = Keyword.get(opts, :needs_attention) == true

    %{
      reason: alert_reason(message, opts),
      severity: alert_severity(needs_attention, opts),
      needs_attention: needs_attention,
      source_ticket_id: issue_number_for(opts)
    }
  end

  defp alert_reason(message, opts) do
    opts
    |> Keyword.get(:reason)
    |> Config.present_string()
    |> case do
      {:ok, reason} -> reason
      _ -> message || ""
    end
  end

  defp alert_severity(needs_attention, opts) do
    opts
    |> Keyword.get(:severity)
    |> Config.present_string()
    |> case do
      {:ok, severity} -> severity
      _ when needs_attention -> "warning"
      _ -> "info"
    end
  end

  defp write_alert_ledger_entry(alert_event, workspace, worker_host) do
    agent =
      cond do
        is_binary(worker_host) -> "system"
        is_binary(workspace) -> Path.basename(workspace)
        true -> "system"
      end

    alert_event
    |> central_alert_json()
    |> Map.put("agent", agent)
    |> AlertLedger.append()
  end

  # Keep the historical central file as an audit-compatible auxiliary output.
  # AlertFeed reads the project-scoped ledger above, which also receives local
  # workspace alerts that intentionally remain absent from this file.
  #
  # This file is per-launch on purpose (#2722): it is a run log, not state. No
  # running code reads it back except the one-time `AlertFeed.backfill/1`
  # import into the durable ledger; the ledger is what survives a restart.
  defp maybe_write_central_alert_feed_entry(alert_event, workspace, worker_host, opts) do
    if is_binary(workspace) and worker_host == nil and not Keyword.get(opts, :central, false) do
      :ok
    else
      write_central_alert_feed_entry(alert_event)
    end
  end

  defp write_central_alert_feed_entry(alert_event) do
    path = Path.join(Paths.log_root_dir(), "alerts.ndjson")

    encoded =
      alert_event
      |> central_alert_json()
      |> Jason.encode!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, encoded <> "\n", [:append]) do
      :ok
    else
      {:error, reason} ->
        Logger.debug("Failed writing central alert feed path=#{path} reason=#{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.debug("Failed writing central alert feed error=#{Exception.message(error)}")
      :ok
  end

  defp central_alert_json(alert_event) do
    Map.new(alert_event, fn
      {:timestamp, %DateTime{} = timestamp} -> {"timestamp", DateTime.to_iso8601(timestamp)}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp publish_to_exchange(topic, message, metadata, opts) do
    payload =
      %{
        "message" => message || "",
        "source" => "alert",
        "reason" => metadata.reason,
        "severity" => metadata.severity,
        "needs_attention" => metadata.needs_attention,
        "source_ticket_id" => metadata.source_ticket_id,
        "topic" => topic,
        source: Keyword.get(opts, :event_source, :system)
      }
      |> Map.merge(Keyword.get(opts, :exchange_payload, %{}))

    payload = if Keyword.get(opts, :refs_only, false), do: Keyword.get(opts, :exchange_payload, %{}), else: payload

    Publisher.publish(topic, payload,
      issue_number: issue_number_for(opts),
      bypass_contamination: Keyword.get(opts, :bypass_contamination, false) or Aiur.ExecutorBindings.attention_topic?(topic),
      identity: Keyword.get(opts, :observation_identity),
      dedup_key: Keyword.get(opts, :dedup_key),
      resource: Keyword.get(opts, :resource),
      resource_version: Keyword.get(opts, :resource_version),
      resource_source: Keyword.get(opts, :resource_source, :poll),
      observation_source: Keyword.get(opts, :observation_source),
      observation_provenance: Keyword.get(opts, :observation_provenance),
      occurred_at: Keyword.get(opts, :occurred_at)
    )
    |> publication_result(opts)
  rescue
    # Ordinary alerts stay best-effort during early boot; durable callers need the failure to retry.
    error -> publication_result({:error, {:publish_failed, error}}, opts)
  catch
    :exit, reason -> publication_result({:error, {:publish_failed, reason}}, opts)
  end

  defp publication_result({:ok, _id, _subscribers}, _opts), do: :ok
  defp publication_result(:deduped, _opts), do: :ok

  defp publication_result(result, opts) do
    if Keyword.get(opts, :durable, false), do: {:error, {:publication_failed, result}}, else: :ok
  end

  defp issue_number_for(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{identifier: id} when is_binary(id) -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp broadcast_agent_alert(name, message, metadata, selected_sound, opts) do
    case identifier_for_alert(opts) do
      identifier when is_binary(identifier) ->
        event =
          AgentEvents.alert_event(name, message,
            reason: metadata.reason,
            severity: metadata.severity,
            needs_attention: metadata.needs_attention,
            source_ticket_id: metadata.source_ticket_id,
            sound: selected_sound
          )

        AgentPubSub.broadcast_alert(identifier, event)

      _ ->
        :ok
    end
  end

  defp identifier_for_alert(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{identifier: identifier} when is_binary(identifier) -> identifier
      identifier when is_binary(identifier) -> identifier
      _ -> Keyword.get(opts, :identifier)
    end
  end

  defp identifier_suffix(opts) do
    case identifier_for_alert(opts) do
      identifier when is_binary(identifier) and identifier != "" -> " (##{identifier})"
      _ -> ""
    end
  end

  defp config_message(%{message: message}), do: message
  defp config_message(_config), do: nil

  @doc false
  @spec categorize_topic(String.t()) :: :needs_input | :stuck | :done | :default
  defdelegate categorize_topic(topic), to: Sound

  @doc false
  @spec os_sound_candidates(atom(), term()) :: [String.t()]
  defdelegate os_sound_candidates(category, os_type), to: Sound

  @doc false
  @spec default_player(String.t()) :: :ok | {:ok, pid()}
  defdelegate default_player(sound), to: Sound

  @doc false
  @spec default_player(String.t(), (String.t() -> String.t() | nil)) :: :ok | {:ok, pid()}
  defdelegate default_player(sound, find_executable_fn), to: Sound

  @doc false
  @spec player_command(term(), (String.t() -> String.t() | nil)) :: {String.t(), (String.t() -> [String.t()])} | :none
  defdelegate player_command(os_type, find_executable_fn), to: Sound

  defp resolve_workspace(%Issue{identifier: identifier}), do: resolve_workspace(identifier)

  defp resolve_workspace(identifier) when is_binary(identifier),
    do: resolve_workspace_for(identifier, &Aiur.Config.workspace_root/0)

  defp resolve_workspace(_issue), do: nil

  # Public (but undocumented) so a test can inject a `workspace_root_fn`
  # that raises, exercising the rescue branch deterministically.
  @doc false
  @spec resolve_workspace_for(String.t(), (-> String.t())) :: String.t() | nil
  def resolve_workspace_for(identifier, workspace_root_fn)
      when is_binary(identifier) and is_function(workspace_root_fn, 0) do
    workspace = Aiur.Workspace.workspace_path_under(workspace_root_fn.(), identifier)

    if File.dir?(workspace), do: workspace, else: nil
  rescue
    _error -> nil
  end
end
