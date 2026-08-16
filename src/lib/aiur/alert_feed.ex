defmodule Aiur.AlertFeed do
  @moduledoc """
  Reads persisted structured alert events from the project-scoped alert ledger.
  """

  alias Aiur.AlertLedger
  alias Aiur.Config
  alias Aiur.Config.Paths
  alias Aiur.Jsonl
  alias Aiur.Workspace.Layout

  @decision_attention_prefix "Executor decision required: "
  @resolution_suffix ".resolved"

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    opts
    |> AlertLedger.paths()
    |> Enum.flat_map(&read_alerts/1)
    |> Enum.sort_by(&{is_nil(Map.get(&1, "timestamp")), Map.get(&1, "timestamp") || ""})
    |> collapse_repeated_resolutions()
    |> resolve_attention_alerts()
    |> maybe_filter_attention(Keyword.get(opts, :needs_attention, false))
    |> maybe_filter_agents(Keyword.get(opts, :agents))
  end

  @doc false
  @spec backfill(keyword()) :: :ok
  def backfill(opts \\ []) do
    unless AlertLedger.backfilled?(opts) do
      AlertLedger.with_backfill_lock(opts, fn -> backfill_locked(opts) end)
    end

    :ok
  end

  defp backfill_locked(opts) do
    existing =
      opts
      |> AlertLedger.paths()
      |> Enum.flat_map(&read_alerts/1)
      |> MapSet.new(&alert_fingerprint/1)

    case append_legacy_alerts(legacy_alert_log_paths(opts), existing, opts) do
      :ok -> AlertLedger.mark_backfilled(opts)
      {:error, _reason} -> :ok
    end
  end

  @doc "Returns active legacy attention alerts in the current project's Decision adapter shape."
  @spec list_decision_attentions(keyword()) :: [map()]
  def list_decision_attentions(opts \\ []) do
    opts
    |> Keyword.put(:needs_attention, true)
    |> list()
    |> Enum.reduce(%{}, &reduce_decision_attention/2)
    |> Map.values()
    |> Enum.sort_by(&{&1.identifier, &1.slug})
  end

  @doc false
  @spec active_system_attention?(String.t(), keyword()) :: boolean()
  def active_system_attention?(topic, opts \\ []) when is_binary(topic) and is_list(opts) do
    opts = opts |> Keyword.put_new(:log_roots, [Paths.log_root_dir()]) |> Keyword.put(:agents, ["system"])

    Enum.any?(list(Keyword.put(opts, :needs_attention, true)), &(&1["topic"] == topic))
  end

  @doc false
  @spec active_ticket_attention?(String.t(), keyword()) :: boolean()
  def active_ticket_attention?(topic, opts \\ []) when is_binary(topic) and is_list(opts) do
    opts = opts |> Keyword.put_new(:log_roots, [Paths.log_root_dir()]) |> Keyword.put(:agents, ["system"])

    Enum.any?(list(Keyword.put(opts, :needs_attention, true)), &(&1["topic"] == topic))
  end

  @doc """
  Returns where the condition behind `topic` currently sits in its
  firing/cleared cycle, according to the durable ledger.

  `:firing` means the most recent record for the condition is the condition
  itself; `:resolved` means it is the condition's resolution; `:unknown` means
  the ledger has never recorded either.
  """
  @spec condition_state(String.t(), keyword()) :: :firing | :resolved | :unknown
  def condition_state(topic, opts \\ []) when is_binary(topic) and is_list(opts) do
    resolution = topic <> @resolution_suffix

    opts
    |> AlertLedger.paths()
    |> Enum.flat_map(&read_alerts/1)
    |> Enum.filter(&(Map.get(&1, "topic") in [topic, resolution]))
    |> Enum.sort_by(&{is_nil(Map.get(&1, "timestamp")), Map.get(&1, "timestamp") || ""})
    |> List.last()
    |> case do
      nil -> :unknown
      %{"topic" => ^resolution} -> :resolved
      _firing -> :firing
    end
  end

  @doc """
  True when `topic` is a resolution whose condition the ledger already records
  as resolved, with no firing record since.

  A resolution reports a *transition*, so re-emitting one while the condition
  has stayed clear says nothing new and only buries the records an Executor
  needs. Emitters consult this to stay edge-triggered even across a process
  restart that drops their in-memory latch.
  """
  @spec duplicate_resolution?(String.t(), keyword()) :: boolean()
  def duplicate_resolution?(topic, opts \\ []) when is_binary(topic) and is_list(opts) do
    case condition_topic(topic) do
      nil -> false
      condition -> condition_state(condition, opts) == :resolved
    end
  end

  # Collapses resolutions that repeat with no intervening firing record, so a
  # ledger already carrying a backlog of them still presents one record per
  # transition. The earliest record of each run survives: it is the one that
  # timestamps the actual transition.
  defp collapse_repeated_resolutions(alerts) do
    alerts
    |> Enum.reduce({[], %{}}, &collapse_resolution_step/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp collapse_resolution_step(alert, {kept, states}) do
    topic = Map.get(alert, "topic") || ""

    case condition_topic(topic) do
      nil -> {[alert | kept], Map.put(states, topic, :firing)}
      condition -> keep_first_resolution(alert, condition, kept, states)
    end
  end

  # The earliest resolution of a run is the one that timestamps the transition;
  # the rest repeat it and are dropped.
  defp keep_first_resolution(alert, condition, kept, states) do
    if Map.get(states, condition) == :resolved do
      {kept, states}
    else
      {[alert | kept], Map.put(states, condition, :resolved)}
    end
  end

  defp condition_topic(topic) do
    case String.replace_suffix(topic, @resolution_suffix, "") do
      ^topic -> nil
      "" -> nil
      condition -> condition
    end
  end

  defp legacy_alert_log_paths(opts) do
    opts
    |> backfill_roots()
    |> Enum.flat_map(&alert_log_paths/1)
    |> Kernel.++(central_alert_log_paths(opts))
    |> Enum.uniq()
  end

  defp backfill_roots(opts) do
    if Keyword.has_key?(opts, :roots), do: roots(opts), else: configured_project_roots()
  end

  defp append_legacy_alerts(paths, existing, opts) do
    paths
    |> Enum.flat_map(&read_legacy_alerts/1)
    |> Enum.reduce_while({:ok, existing}, fn alert, {:ok, seen} ->
      case append_legacy_alert(alert, seen, opts) do
        {:ok, updated_seen} -> {:cont, {:ok, updated_seen}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp append_legacy_alert(alert, seen, opts) do
    fingerprint = alert_fingerprint(alert)

    if MapSet.member?(seen, fingerprint) do
      {:ok, seen}
    else
      case AlertLedger.append(alert, opts) do
        :ok -> {:ok, MapSet.put(seen, fingerprint)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp roots(opts) do
    configured_roots = Keyword.get(opts, :roots)

    roots =
      case configured_roots do
        list when is_list(list) -> list
        _ -> [configured_workspace_root(), Path.join(user_home(), ".aiur/workspaces")]
      end

    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  defp configured_workspace_root do
    Config.workspace_root()
  rescue
    _ -> nil
  end

  defp configured_project_roots do
    [configured_workspace_root(), Path.join(user_home(), ".aiur/workspaces")]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&project_root/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp project_root(root) do
    root
    |> Layout.issue_workspace_path("__aiur_attention_probe__")
    |> Path.dirname()
  rescue
    _ -> nil
  end

  defp central_alert_log_paths(opts) do
    opts
    |> log_roots()
    |> Enum.map(&Path.join(&1, "alerts.ndjson"))
    |> Enum.filter(&File.regular?/1)
  end

  defp log_roots(opts) do
    configured_roots = Keyword.get(opts, :log_roots)

    roots =
      case configured_roots do
        list when is_list(list) -> list
        _ -> [configured_log_root()]
      end

    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  defp configured_log_root do
    Paths.log_root_dir()
  rescue
    _ -> nil
  end

  defp user_home do
    System.user_home() || "."
  end

  defp alert_log_paths(root) do
    [
      Path.join(root, "*/logs/agent.ndjson"),
      Path.join(root, "*/*/logs/agent.ndjson"),
      Path.join(root, "*/*/*/logs/agent.ndjson")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
  end

  defp read_alerts(path) do
    path
    |> Jsonl.stream()
    |> Stream.filter(&(Map.get(&1, "event") == "alert"))
    |> Enum.map(&normalize_alert(&1, agent_from_path(path, &1)))
  rescue
    _ -> []
  end

  defp read_legacy_alerts(path) do
    path
    |> Jsonl.stream()
    |> Stream.filter(&(Map.get(&1, "event") == "alert"))
    |> Enum.to_list()
  rescue
    _ -> []
  end

  defp normalize_alert(alert, path_agent) do
    topic = string_field(alert, "topic") || string_field(alert, "name") || ""

    reason =
      normalize_legacy_role_copy(string_field(alert, "reason") || string_field(alert, "message") || last_topic_segment(topic))

    message = normalize_legacy_role_copy(string_field(alert, "message") || reason)

    needs_attention = Map.get(alert, "needs_attention") == true
    source_ticket_id = string_field(alert, "source_ticket_id") || parse_ticket(topic) || path_agent
    agent = alert_agent(alert, path_agent)

    %{
      "timestamp" => string_field(alert, "timestamp"),
      "source_ticket_id" => source_ticket_id,
      "ticket" => source_ticket_id,
      "agent" => agent,
      "topic" => topic,
      "name" => topic,
      "reason" => reason,
      "message" => message,
      "severity" => string_field(alert, "severity") || default_severity(needs_attention),
      "needs_attention" => needs_attention
    }
  end

  defp maybe_filter_attention(alerts, true), do: Enum.filter(alerts, &(Map.get(&1, "needs_attention") == true))
  defp maybe_filter_attention(alerts, _), do: alerts

  defp maybe_filter_agents(alerts, agents) when is_list(agents), do: Enum.filter(alerts, &(&1["agent"] in agents))
  defp maybe_filter_agents(alerts, _agents), do: alerts

  defp resolve_attention_alerts(alerts) do
    Enum.reduce(alerts, [], fn alert, active_alerts ->
      case resolved_attention_key(alert) do
        nil -> collapse_repeated_attention(alert, active_alerts)
        key -> [alert | Enum.reject(active_alerts, &(attention_alert_key(&1) == key))]
      end
    end)
    |> Enum.reverse()
  end

  defp collapse_repeated_attention(%{"needs_attention" => true} = alert, active_alerts) do
    case attention_alert_key(alert) do
      nil ->
        [alert | active_alerts]

      key ->
        {previous, remaining} = Enum.split_with(active_alerts, &(attention_alert_key(&1) == key))

        first_opened_at =
          previous
          |> List.first(%{})
          |> Map.get("timestamp")

        collapsed = Map.put(alert, "timestamp", first_opened_at || Map.get(alert, "timestamp"))
        [collapsed | remaining]
    end
  end

  defp collapse_repeated_attention(alert, active_alerts), do: [alert | active_alerts]

  defp resolved_attention_key(%{"topic" => "ticket." <> rest, "needs_attention" => false}) do
    case String.split(rest, ".agent.attention.", parts: 2) do
      [ticket, slug_and_suffix] ->
        case String.trim_trailing(slug_and_suffix, ".resolved") do
          ^slug_and_suffix -> nil
          slug -> {ticket, slug}
        end

      _ ->
        resolved_ticket_agent_attention_key(rest)
    end
  end

  defp resolved_attention_key(%{"topic" => "system." <> rest, "needs_attention" => false}) do
    case String.trim_trailing(rest, ".resolved") do
      ^rest -> nil
      topic -> {:system, topic}
    end
  end

  defp resolved_attention_key(_alert), do: nil

  defp resolved_ticket_agent_attention_key(rest) do
    case String.trim_trailing(rest, ".resolved") do
      ^rest -> nil
      topic -> {:ticket, topic}
    end
  end

  defp attention_alert_key(%{"topic" => "ticket." <> rest}) do
    case String.split(rest, ".agent.attention.", parts: 2) do
      [ticket, slug] -> {ticket, slug}
      _ -> {:ticket, rest}
    end
  end

  defp attention_alert_key(%{"topic" => "system." <> rest}), do: {:system, rest}

  defp attention_alert_key(_alert), do: nil

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp parse_ticket(topic) do
    case Regex.run(~r/\Aticket\.([^.]+)\./, topic) do
      [_, ticket] -> ticket
      _ -> nil
    end
  end

  defp last_topic_segment(""), do: ""
  defp last_topic_segment(topic), do: topic |> String.split(".") |> List.last()

  defp default_severity(true), do: "warning"
  defp default_severity(false), do: "info"

  defp alert_agent(alert, path_agent), do: string_field(alert, "agent") || path_agent

  defp alert_fingerprint(alert) do
    alert
    |> Map.take(~w(timestamp source_ticket_id topic reason message severity needs_attention))
    |> Jason.encode!()
  end

  # Persisted alerts keep their original bytes for audit/replay compatibility;
  # only the presentation projection adopts the current role terminology.
  defp normalize_legacy_role_copy("Operator decision " <> rest), do: "Executor decision " <> rest
  defp normalize_legacy_role_copy(value), do: value

  defp reduce_decision_attention(alert, attentions) do
    case to_decision_attention(alert) do
      nil ->
        attentions

      attention ->
        key = {attention.identifier, attention.slug}

        Map.update(attentions, key, attention, fn previous ->
          %{attention | source_created_at: previous.source_created_at || attention.source_created_at}
        end)
    end
  end

  defp to_decision_attention(%{"needs_attention" => true, "topic" => topic} = alert) do
    case Regex.run(~r/\Aticket\.([^.]+)\.agent\.attention\.([a-z0-9][a-z0-9.-]{0,63})\z/, topic) do
      [_, identifier, slug] ->
        question = attention_question(alert)

        if question == "" or internal_decision_alert?(slug) do
          nil
        else
          %{
            identifier: identifier,
            slug: slug,
            question: question,
            topic: topic,
            source_created_at: parse_timestamp(Map.get(alert, "timestamp"))
          }
        end

      _ ->
        nil
    end
  end

  defp to_decision_attention(_alert), do: nil

  defp internal_decision_alert?(slug) do
    String.starts_with?(slug, ["decision-delivery-", "decision-lifecycle-persistence-"])
  end

  defp attention_question(alert) do
    alert
    |> Map.get("reason", Map.get(alert, "message", ""))
    |> String.replace_prefix(@decision_attention_prefix, "")
    |> String.trim()
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_timestamp(_timestamp), do: nil

  defp agent_from_path(path, alert) do
    if Path.basename(path) == "alerts.ndjson" do
      "system"
    else
      string_field(alert, "agent") || string_field(alert, "source_ticket_id") || agent_from_workspace_path(path)
    end
  end

  defp agent_from_workspace_path(path) do
    if String.ends_with?(Path.basename(path), ".alerts.ndjson") do
      "system"
    else
      path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.basename()
    end
  end
end
