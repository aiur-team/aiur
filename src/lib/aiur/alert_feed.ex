defmodule Aiur.AlertFeed do
  @moduledoc """
  Reads persisted structured alert events from agent workspaces.
  """

  alias Aiur.Config

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    opts
    |> roots()
    |> Enum.flat_map(&alert_log_paths/1)
    |> Enum.flat_map(&read_alerts/1)
    |> maybe_filter_attention(Keyword.get(opts, :needs_attention, false))
    |> Enum.sort_by(&Map.get(&1, "timestamp", ""))
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
    |> File.stream!([], :line)
    |> Stream.map(&decode_line/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(&(Map.get(&1, "event") == "alert"))
    |> Enum.map(&normalize_alert(&1, agent))
  rescue
    _ -> []
  end

  defp decode_line(line) do
    line
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, %{} = decoded} -> decoded
      _ -> nil
    end
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
    path
    |> Path.dirname()
    |> Path.dirname()
    |> Path.basename()
  end
end
