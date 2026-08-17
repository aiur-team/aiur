defmodule Aiur.ExecutorEvents do
  @moduledoc """
  Durable, Executor-scoped events.

  The Exchange provides immediate fan-out, while this small journal and cursor
  store make an Executor restart safe. It deliberately has no ticket identity:
  an Executor is a run principal, not another managed ticket agent.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Decision
  alias Aiur.DecisionLog
  alias Aiur.Events.Exchange
  alias Aiur.Events.IdGenerator
  alias Aiur.Events.Publisher
  alias Aiur.Events.Sanitizer
  alias Aiur.Events.Topic
  alias Aiur.Executor.StatePaths
  alias Aiur.ExecutorBindings
  alias Aiur.ExecutorWakeProjection
  alias Aiur.JSONSafe
  alias Aiur.JsonStore

  @default_topic "executor.#"

  @doc """
  Publish an `executor.decision.deferred` event for a decision.

  The decision_id dedup gates only the journal append: a repeat call for an
  already-journaled decision is a no-op returning the cached event id. An
  explicit `renotify: true` (the dashboard's "Notify Executor again") always
  publishes a fresh event — new event id, same decision_id, `renotify: true`
  attribute — so listeners whose cursor already passed the original id are
  woken again.
  """
  @spec publish_deferred(Decision.t(), keyword()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def publish_deferred(%Decision{} = decision, opts \\ []) do
    renotify? = Keyword.get(opts, :renotify, false)

    case deferred_event_id(decision.decision_id) do
      {:ok, _id} when renotify? ->
        publish("executor.decision.deferred", deferred_payload(decision, true), source: :internal)

      {:ok, id} ->
        {:ok, id, 0}

      :not_found ->
        publish("executor.decision.deferred", deferred_payload(decision, false), source: :internal)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Publish a newly accepted Command to the durable Executor stream."
  @spec publish_requested(Decision.t()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def publish_requested(%Decision{} = decision) do
    publish("executor.decision.requested", requested_payload(decision), source: :internal)
  end

  @spec publish(String.t(), map(), keyword()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def publish(topic, payload, opts \\ []) when is_binary(topic) and is_map(payload) do
    source = Keyword.get(opts, :source, :executor_cli)

    with :ok <- validate_publish_topic(topic),
         :ok <- reject_github_source(source),
         :ok <- reject_github_payload_source(payload),
         {:ok, id} <- IdGenerator.reserve_durable_id(),
         event <- payload |> JSONSafe.normalize() |> Map.merge(%{"id" => id, "topic" => topic, "source" => source_name(source)}),
         :ok <- append_event(event) do
      Publisher.publish_persisted(topic, payload, id, source: source)
    end
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    with :ok <- validate_binding_topic(topic) do
      state = subscription_state()
      subscriptions = add_subscription(state["subscribed_to"], topic, "manual:executor")
      persist_subscription_state(%{state | "subscribed_to" => subscriptions})
    end
  end

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(topic) when is_binary(topic) do
    with :ok <- validate_binding_topic(topic) do
      state = subscription_state()
      persist_subscription_state(%{state | "subscribed_to" => Enum.reject(state["subscribed_to"], &(&1["topic"] == topic))})
    end
  end

  @spec subscriptions() :: [String.t()]
  def subscriptions, do: Enum.map(subscription_state()["subscribed_to"], & &1["topic"])

  @doc false
  @spec subscription_entries() :: [map()]
  def subscription_entries, do: subscription_state()["subscribed_to"]

  @doc false
  @spec reconcile_subscriptions([{String.t(), String.t()}]) :: :ok | {:error, term()}
  def reconcile_subscriptions(defaults) when is_list(defaults) do
    state = subscription_state()
    default_topics = MapSet.new(defaults, &elem(&1, 0))

    kept =
      Enum.reject(state["subscribed_to"], fn entry ->
        String.ends_with?(entry["reason"], ":auto") and not MapSet.member?(default_topics, entry["topic"])
      end)

    subscriptions = Enum.reduce(defaults, kept, fn {topic, reason}, entries -> add_subscription(entries, topic, reason) end)
    persist_subscription_state(%{state | "subscribed_to" => subscriptions})
  end

  @spec last_seen_event_id() :: non_neg_integer() | nil
  def last_seen_event_id, do: subscription_state()["last_seen_event_id"]

  @doc "Streams persisted missed events, then live Exchange events, as JSON lines until interrupted."
  @spec listen(keyword()) :: no_return()
  def listen(opts \\ []) do
    topic = Keyword.get(opts, :topic, @default_topic)
    :ok = subscribe(topic)
    patterns = subscriptions()

    try do
      Enum.each(patterns, &Exchange.subscribe/1)

      case replay(patterns, last_seen_event_id()) do
        {:ok, events} ->
          Enum.each(events, &deliver/1)
          receive_events(patterns)

        {:error, reason} ->
          raise "Executor event journal is unavailable: #{inspect(reason)}"
      end
    after
      Enum.each(patterns, &safe_unsubscribe/1)
    end
  end

  @doc false
  @spec replay([String.t()], non_neg_integer() | nil) :: {:ok, [map()]} | {:error, term()}
  def replay(patterns, cursor) when is_list(patterns) do
    cursor = cursor || 0
    entries = subscription_entries()

    with {:ok, events} <- journal_events() do
      {:ok,
       events
       |> Enum.filter(&replayable?(&1, patterns, entries, cursor))
       |> Enum.sort_by(&Map.get(&1, "id", 0))}
    end
  end

  defp receive_events(patterns) do
    receive do
      {:event, event} ->
        topic = Map.get(event, :topic) || Map.get(event, "topic")

        if matches_any?(patterns, topic) do
          deliver(event)
        end

        receive_events(patterns)
    end
  end

  defp deliver(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    if is_binary(topic) and String.starts_with?(topic, "executor.") do
      deliver_executor_event(event)
    else
      deliver_wake_event(event)
    end
  end

  defp deliver_executor_event(event) do
    id = Map.get(event, :id) || Map.get(event, "id")

    if not is_integer(id) or id > (last_seen_event_id() || 0) do
      IO.puts(Jason.encode!(scrub_untrusted_output(event)))
      advance_cursor(id)
    end
  end

  defp deliver_wake_event(event) do
    case ExecutorWakeProjection.project(event) do
      {:ok, record} -> IO.puts(Jason.encode!(record))
      :ignore -> :ok
    end
  end

  # Command payloads carry agent-authored free text (title/options/context)
  # whose provenance includes GitHub content. Before the JSON line reaches the
  # Executor session, run the Sanitizer's instruction-carrier strip pass over
  # those fields and name them in a top-level "untrusted_fields" key so the
  # consumer treats them as data, not instructions.
  @command_topics ~w(executor.decision.requested executor.decision.deferred)
  @untrusted_command_fields ~w(title options context recommendation consequence_of_delay)
  @untrusted_command_field_keys [
    :title,
    :options,
    :context,
    :recommendation,
    :consequence_of_delay,
    "title",
    "options",
    "context",
    "recommendation",
    "consequence_of_delay"
  ]

  @doc false
  @spec scrub_untrusted_output(map()) :: map()
  def scrub_untrusted_output(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    if topic in @command_topics do
      event
      |> scrub_command_fields()
      |> Map.put("untrusted_fields", @untrusted_command_fields)
    else
      event
    end
  end

  defp scrub_command_fields(event) do
    Enum.reduce(@untrusted_command_field_keys, event, &scrub_command_field/2)
  end

  defp scrub_command_field(key, event) do
    case Map.fetch(event, key) do
      {:ok, value} -> Map.put(event, key, deep_strip(value))
      :error -> event
    end
  end

  defp deep_strip(text) when is_binary(text), do: Sanitizer.strip_untrusted_text(text)
  defp deep_strip(list) when is_list(list), do: Enum.map(list, &deep_strip/1)
  defp deep_strip(%_struct{} = struct), do: struct |> Map.from_struct() |> deep_strip()
  defp deep_strip(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, deep_strip(value)} end)
  defp deep_strip(other), do: other

  defp advance_cursor(id) when is_integer(id) do
    state = subscription_state()
    current = state["last_seen_event_id"] || 0
    persist_subscription_state(%{state | "last_seen_event_id" => max(current, id)})
  end

  defp advance_cursor(_id), do: :ok

  @doc false
  @spec validate_syntax(String.t()) :: :ok | {:error, :invalid_topic}
  def validate_syntax(topic) do
    if String.trim(topic) == "" or String.starts_with?(topic, ".") or String.ends_with?(topic, ".") or String.contains?(topic, "..") do
      {:error, :invalid_topic}
    else
      :ok
    end
  end

  @doc false
  @spec validate_publish_topic(String.t()) :: :ok | {:error, :invalid_topic}
  def validate_publish_topic(topic) do
    with :ok <- validate_syntax(topic), true <- String.starts_with?(topic, "executor.") do
      :ok
    else
      false -> {:error, :invalid_topic}
      error -> error
    end
  end

  @doc false
  @spec validate_binding_topic(String.t()) :: :ok | {:error, :invalid_topic | :binding_not_allowlisted}
  def validate_binding_topic(topic) do
    with :ok <- validate_syntax(topic), true <- ExecutorBindings.allowlisted?(topic) do
      :ok
    else
      false -> {:error, :binding_not_allowlisted}
      error -> error
    end
  end

  defp reject_github_source(source) when source in [:github, "github"], do: {:error, :executor_namespace_rejects_github_source}
  defp reject_github_source(%{kind: :github}), do: {:error, :executor_namespace_rejects_github_source}
  defp reject_github_source(%{"kind" => "github"}), do: {:error, :executor_namespace_rejects_github_source}
  defp reject_github_source(_source), do: :ok

  defp reject_github_payload_source(payload) do
    payload
    |> Map.get(:source, Map.get(payload, "source"))
    |> reject_github_source()
  end

  defp source_name(source) when is_atom(source), do: Atom.to_string(source)
  defp source_name(source), do: source

  defp deferred_payload(decision, renotify?) do
    %{
      decision_id: decision.decision_id,
      issue_identifier: decision.ticket.identifier,
      title: decision.question,
      options: decision.options,
      context: decision.context,
      deferred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      provenance: :operator_dashboard,
      renotify: renotify?
    }
  end

  defp requested_payload(decision) do
    %{
      decision_id: decision.decision_id,
      decision_version: decision.version,
      issue_identifier: decision.ticket.identifier,
      title: decision.question,
      options: decision.options,
      context: decision.context,
      recommendation: decision.recommendation,
      authority: decision.authority,
      urgency: decision.urgency,
      blocking: decision.blocking,
      reversibility: decision.reversibility,
      consequence_of_delay: decision.consequence_of_delay,
      created_at: decision.created_at,
      provenance: :decision_store
    }
  end

  @doc """
  Publishes `executor.decision.requested` only if this exact Decision version
  is not already journaled.

  This is the retry/reconciliation entry point, so it must converge rather than
  amplify: an already-published version returns its cached event id with zero
  new subscribers, exactly like `publish_deferred/2`. Publishing a fresh event
  here made every failed retry re-deliver Commands the Executor had already
  seen.
  """
  @spec ensure_requested(Decision.t()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def ensure_requested(%Decision{} = decision) do
    case requested_event_id(decision.decision_id, decision.version) do
      {:ok, id} -> {:ok, id, 0}
      :not_found -> publish_requested(decision)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec reconcile_requested([Decision.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_requested(decisions) when is_list(decisions) do
    with {:ok, events} <- journal_events() do
      decisions
      |> missing_requested(events)
      |> publish_missing_requested()
    end
  end

  defp missing_requested(decisions, events) do
    existing =
      events
      |> Enum.filter(&(&1["topic"] == "executor.decision.requested"))
      |> MapSet.new(&{&1["decision_id"], &1["decision_version"]})

    Enum.reject(decisions, &MapSet.member?(existing, {&1.decision_id, &1.version}))
  end

  # Never halts part-way. Halting left the untried tail unpublished while the
  # caller retried the whole batch, so every already-published Decision was
  # published a second time. Each Decision is attempted exactly once here and
  # only the still-unpublished ones can be retried by the caller.
  defp publish_missing_requested(decisions) do
    {published, failures} =
      Enum.reduce(decisions, {0, []}, fn decision, {count, failures} ->
        case publish_requested(decision) do
          {:ok, _id, _subscribers} -> {count + 1, failures}
          {:error, reason} -> {count, [reason | failures]}
        end
      end)

    case Enum.reverse(failures) do
      [] -> {:ok, published}
      [reason | _rest] -> {:error, reason}
    end
  end

  defp requested_event_id(decision_id, version) do
    with {:ok, events} <- journal_events() do
      case Enum.find(events, &requested_event?(&1, decision_id, version)) do
        %{"id" => id} when is_integer(id) -> {:ok, id}
        _event -> :not_found
      end
    end
  end

  defp requested_event?(event, decision_id, version) do
    event["topic"] == "executor.decision.requested" and
      event["decision_id"] == decision_id and
      event["decision_version"] == version
  end

  defp deferred_event_id(decision_id) do
    with {:ok, events} <- journal_events() do
      case Enum.find(events, &(&1["topic"] == "executor.decision.deferred" and &1["decision_id"] == decision_id)) do
        %{"id" => id} when is_integer(id) -> {:ok, id}
        _event -> :not_found
      end
    end
  end

  defp replay_validator(%{"id" => id, "topic" => topic} = event) when is_integer(id) and is_binary(topic), do: {:ok, event}
  defp replay_validator(_event), do: {:error, :invalid_executor_event}

  defp journal_events do
    case DecisionLog.replay(journal_path(), &replay_validator/1) do
      {:ok, events, nil} ->
        {:ok, events}

      {:ok, _events, {:corrupt, line, reason}} ->
        report_corruption(line, reason)
        {:error, {:corrupt, line, reason}}

      {:error, reason} ->
        Logger.error("aiur_executor_events phase=journal_unavailable reason=#{inspect(reason)}")
        {:error, {:journal_unavailable, reason}}
    end
  end

  defp report_corruption(line, reason) do
    Logger.error("aiur_executor_events phase=journal_corrupt path=#{journal_path()} line=#{line} reason=#{inspect(reason)}")

    _ =
      Alerts.emit_custom(
        "executor_events.corrupted",
        "Executor event journal is corrupt at #{journal_path()} line #{line}; listener replay is stopped.",
        needs_attention: true
      )
  end

  defp append_event(event) do
    with :ok <- DecisionLog.prepare(StatePaths.dir(), journal_path()) do
      DecisionLog.append(journal_path(), event)
    end
  end

  defp subscription_state do
    case JsonStore.read(subscription_path()) do
      {:ok, %{} = state} ->
        %{
          "subscribed_to" => normalize_subscriptions(state["subscribed_to"]),
          "last_seen_event_id" => state["last_seen_event_id"]
        }

      _ ->
        %{"subscribed_to" => [], "last_seen_event_id" => nil}
    end
  end

  defp persist_subscription_state(state) do
    JsonStore.write!(subscription_path(), state)
    :ok
  rescue
    error -> {:error, {:subscription_store_unavailable, Exception.message(error)}}
  end

  defp add_subscription(entries, topic, reason) do
    if Enum.any?(entries, &(&1["topic"] == topic)) do
      entries
    else
      entries ++
        [
          %{
            "topic" => topic,
            "reason" => reason,
            "subscription_created_at_event_id" => IdGenerator.peek()
          }
        ]
    end
  end

  defp normalize_subscriptions(subscriptions) do
    Enum.map(List.wrap(subscriptions), fn
      topic when is_binary(topic) ->
        %{"topic" => topic, "reason" => "manual:legacy", "subscription_created_at_event_id" => 0}

      %{} = entry ->
        %{
          "topic" => entry["topic"] || entry[:topic],
          "reason" => entry["reason"] || entry[:reason] || "manual:legacy",
          "subscription_created_at_event_id" => entry["subscription_created_at_event_id"] || entry[:subscription_created_at_event_id] || 0
        }
    end)
  end

  defp matches_any?(patterns, topic) when is_binary(topic), do: Enum.any?(patterns, &Topic.matches?(&1, topic))
  defp matches_any?(_patterns, _topic), do: false

  defp replayable?(event, patterns, entries, cursor) do
    id = Map.get(event, "id", 0)
    topic = Map.get(event, "topic")

    is_integer(id) and id > cursor and matches_any?(patterns, topic) and
      Enum.any?(entries, fn entry ->
        floor = entry["subscription_created_at_event_id"] || 0
        is_binary(entry["topic"]) and is_integer(floor) and id > floor and Topic.matches?(entry["topic"], topic)
      end)
  end

  defp safe_unsubscribe(topic) do
    Exchange.unsubscribe(topic)
  rescue
    _error -> :ok
  end

  defp journal_path, do: StatePaths.journal_path()
  defp subscription_path, do: StatePaths.subscriptions_path()
end
