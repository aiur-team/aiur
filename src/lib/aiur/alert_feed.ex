defmodule Aiur.AlertFeed do
  @moduledoc """
  Reads persisted structured alert events from agent workspaces.
  """

  alias Aiur.Config
  alias Aiur.Config.Paths
  alias Aiur.Jsonl

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    workspace_alert_log_paths(opts)
    |> Kernel.++(central_alert_log_paths(opts))
    |> Enum.uniq()
    |> Enum.flat_map(&read_alerts/1)
    |> Enum.sort_by(&Map.get(&1, "timestamp", ""))
    |> resolve_attention_alerts()
    |> maybe_filter_attention(Keyword.get(opts, :needs_attention, false))
  end

  defp workspace_alert_log_paths(opts) do
    opts
    |> roots()
    |> Enum.flat_map(&alert_log_paths/1)
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
    agent = agent_from_path(path)

    path
    |> Jsonl.stream()
    |> Stream.filter(&(Map.get(&1, "event") == "alert"))
    |> Enum.map(&normalize_alert(&1, agent))
  rescue
    _ -> []
  end

  defp normalize_alert(alert, agent) do
    topic = string_field(alert, "topic") || string_field(alert, "name") || ""
    reason = string_field(alert, "reason") || string_field(alert, "message") || last_topic_segment(topic)
    needs_attention = Map.get(alert, "needs_attention") == true
    source_ticket_id = string_field(alert, "source_ticket_id") || parse_ticket(topic) || agent

    %{
      "timestamp" => string_field(alert, "timestamp"),
      "source_ticket_id" => source_ticket_id,
      "ticket" => source_ticket_id,
      "agent" => agent,
      "topic" => topic,
      "name" => topic,
      "reason" => reason,
      "message" => string_field(alert, "message") || reason,
      "severity" => string_field(alert, "severity") || default_severity(needs_attention),
      "needs_attention" => needs_attention
    }
  end

  defp maybe_filter_attention(alerts, true), do: Enum.filter(alerts, &(Map.get(&1, "needs_attention") == true))
  defp maybe_filter_attention(alerts, _), do: alerts

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
      nil -> [alert | active_alerts]
      key -> [alert | Enum.reject(active_alerts, &(attention_alert_key(&1) == key))]
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
        nil
    end
  end

  defp resolved_attention_key(_alert), do: nil

  defp attention_alert_key(%{"topic" => "ticket." <> rest}) do
    case String.split(rest, ".agent.attention.", parts: 2) do
      [ticket, slug] -> {ticket, slug}
      _ -> nil
    end
  end

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

  defp agent_from_path(path) do
    if Path.basename(path) == "alerts.ndjson" do
      "system"
    else
      agent_from_workspace_path(path)
    end
  end

  defp agent_from_workspace_path(path) do
    path
    |> Path.dirname()
    |> Path.dirname()
    |> Path.basename()
  end
end
