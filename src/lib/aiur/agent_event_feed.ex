defmodule Aiur.AgentEventFeed do
  @moduledoc """
  Bounded, durable event feed for a single agent.

  Badge mapping is intentionally derived in this one place:

    * `:command` and `:tool` are `EMIT`: they record the agent acting on an
      external surface (a shell command or a tool call).
    * `:user` is `CONSUME`: it is input the agent receives from the Executor.
    * `:assistant` is `AGENT`: it is the agent's own conversational output.
    * `:system` is `SYSTEM`: it denotes framework/provider context rather than
      agent intent.
    * `:reasoning` and `:alert` are `INFO`: neither honestly asserts a
      directional action. Alerts are notifications, and reasoning is internal
      context.

  The feed never invents a diff. Only a provider `changes[].diff` value is
  rendered as a diff entry; every other payload remains a message. In
  particular, pane-oriented tool output is not proof of a file change.
  """

  alias Aiur.IssueLog

  @default_limit 7
  @max_limit 50

  @type result :: {:ok, map()} | {:error, :invalid_limit | :invalid_cursor | atom()}

  @spec list(String.t(), map()) :: result()
  def list(identifier, params \\ %{})

  def list(identifier, params) when is_binary(identifier) and is_map(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit", @default_limit)),
         {:ok, before} <- parse_cursor(Map.get(params, "cursor")),
         {:ok, page} <- IssueLog.read_tail(identifier, limit: limit, before: before) do
      {:ok,
       %{
         events: Enum.map(page.events, &entry/1),
         pagination: %{limit: limit, next_cursor: page.next_cursor}
       }}
    end
  end

  def list(_identifier, _params), do: {:error, :invalid_limit}

  @doc """
  Maps every persisted transcript role to one of the five Stream Deck badges.

  The module documentation records the rationale for every role so callers do
  not re-interpret directionality at each rendering surface.
  """
  @spec badge(atom() | String.t()) :: String.t()
  def badge(:command), do: "EMIT"
  def badge(:tool), do: "EMIT"
  def badge(:user), do: "CONSUME"
  def badge(:assistant), do: "AGENT"
  def badge(:system), do: "SYSTEM"
  def badge(:reasoning), do: "INFO"
  def badge(:alert), do: "INFO"
  def badge(role) when is_binary(role), do: role |> role_atom() |> badge()

  defp entry(%{"role" => role, "payload" => payload} = event) when is_map(payload) do
    role = role_atom(role)
    if role == :tool, do: diff_entry(event, payload), else: message_entry(event, role)
  end

  defp entry(%{"role" => role} = event), do: message_entry(event, role_atom(role))
  defp entry(_event), do: %{type: "message", badge: "INFO", role: "system", body: ""}

  defp diff_entry(event, %{"tool" => "edit", "changes" => changes}) when is_list(changes) do
    Enum.find_value(changes, &provider_diff_entry(event, &1)) || message_entry(event, :tool)
  end

  defp diff_entry(event, _payload), do: message_entry(event, :tool)

  defp provider_diff_entry(event, %{"diff" => output} = change) when is_binary(output) and output != "" do
    diff_entry(event, output, Map.get(change, "path"))
  end

  defp provider_diff_entry(_event, _change), do: nil

  defp diff_entry(event, output, path) do
    %{
      type: "diff",
      badge: badge(:tool),
      role: "tool",
      timestamp: Map.get(event, "timestamp"),
      msg_id: Map.get(event, "msg_id"),
      turn_id: Map.get(event, "turn_id"),
      path: path || diff_path(output, Map.get(event, "body", "")),
      additions: changed_line_count(output, "+"),
      deletions: changed_line_count(output, "-"),
      line: changed_line(output)
    }
  end

  defp message_entry(event, role) do
    %{
      type: "message",
      badge: badge(role),
      role: Atom.to_string(role),
      body: Map.get(event, "body", ""),
      timestamp: Map.get(event, "timestamp"),
      msg_id: Map.get(event, "msg_id"),
      turn_id: Map.get(event, "turn_id")
    }
  end

  defp parse_limit(value) when is_integer(value) and value in 1..@max_limit, do: {:ok, value}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..@max_limit -> {:ok, limit}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_), do: {:error, :invalid_limit}
  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(value) when is_binary(value) do
    case Integer.parse(value) do
      {cursor, ""} when cursor >= 0 -> {:ok, value}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp parse_cursor(_), do: {:error, :invalid_cursor}

  defp role_atom(role) when is_atom(role), do: role
  defp role_atom(role) when is_binary(role) and role in ["user", "assistant", "system", "command", "alert", "reasoning", "tool"], do: String.to_existing_atom(role)
  defp role_atom(_), do: :system

  defp diff_path(output, fallback) do
    output
    |> String.split("\n")
    |> Enum.find_value(fallback, fn
      "+++ b/" <> path -> path
      "+++ " <> path -> path
      _ -> nil
    end)
  end

  defp changed_line_count(output, marker) do
    output
    |> String.split("\n")
    |> Enum.count(&changed_line?(&1, marker))
  end

  defp changed_line?("+++" <> _rest, "+"), do: false
  defp changed_line?("---" <> _rest, "-"), do: false
  defp changed_line?(line, marker), do: String.starts_with?(line, marker)

  defp changed_line(output) do
    lines = String.split(output, "\n")

    Enum.find_value(lines, fn
      "+" <> "+" <> _ -> nil
      "+" <> line -> line
      _ -> nil
    end) ||
      Enum.find_value(lines, "", fn
        "-" <> "-" <> _ -> nil
        "-" <> line -> line
        _ -> nil
      end)
  end
end
