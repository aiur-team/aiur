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

  ## Two sources, two meanings

  `list/2` reads the agent's **provider transcript** — the individual
  user/assistant/tool/command messages of the conversation. `bus_events/2`
  reads the ticket's **shared event bus** log — the `ticket.<id>.…` topics that
  `Aiur.Events.Publisher` fans out and `Aiur.IssueLog.record_event/3` persists:
  progress and phase changes, inbound comments, CI and PR transitions,
  decisions and attentions.

  They are deliberately separate files and separate functions. A transcript
  message is something the agent *said*; a bus event is something that
  *happened to the ticket*. The Stream Deck logs surface shows one key per bus
  event and uses the transcript as the detail underneath each one, so keeping
  the two reads apart is what stops a chatty turn from burying the ticket's
  actual history.
  """

  alias Aiur.IssueLog

  @default_limit 7
  @max_limit 50
  @default_bus_limit 40
  # A five-row panel scrolls, so more than a screenful of one diff is useful —
  # but a provider can emit a thousand-line hunk, and every line of it would be
  # carried on every relay flush.
  @max_diff_lines 24

  # Written-out names for the topics a ticket actually publishes. The dotted
  # routing key is precise but unreadable at key-face size, and the fallback
  # below cannot know that "pr" is an initialism or that "review_comment" is one
  # noun. Anything absent here still renders, just less prettily.
  @topic_labels %{
    "agent.progress" => "Progress",
    "agent.progress.checkin" => "Progress check-in",
    "agent.progress.phase" => "Phase change",
    "agent.blocked" => "Blocked",
    "agent.unblocked" => "Unblocked",
    "agent.paused" => "Paused",
    "agent.unpaused" => "Resumed",
    "agent.pause.request" => "Pause requested",
    "agent.remote_control" => "Remote control",
    "agent.error.tokens_exhausted" => "Tokens exhausted",
    "issue.commented" => "Comment",
    "pr.opened" => "PR opened",
    "pr.merged" => "PR merged",
    "pr.review_comment" => "Review comment",
    "ci.passed" => "CI passed",
    "ci.failed" => "CI failed",
    "decision.requested" => "Decision requested",
    "decision.acknowledged" => "Decision seen",
    "decision.resolved" => "Decision resolved"
  }

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
  Reads this ticket's shared-event-bus history, oldest first.

  Every row the ticket's `[event:<kind>]` log holds becomes one entry:
  `:emit` and `:self` for events this side published, `:consumed` for events
  delivered to the agent, `:emit_alert` for operator-facing alerts. The kind is
  what carries direction, so it — not the topic — chooses the badge; the topic
  supplies the human label.

  A missing or unreadable log yields an empty list. An agent that has published
  nothing is a normal state, not an error, and the logs surface still has its
  origin event to anchor on.
  """
  @spec bus_events(String.t(), keyword()) :: [map()]
  def bus_events(identifier, opts \\ []) when is_binary(identifier) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_bus_limit)

    identifier
    |> IssueLog.event_history(kinds: [:emit, :emit_alert, :consumed, :self], limit: limit)
    |> history_rows()
    |> Enum.map(&bus_entry/1)
  end

  @doc """
  Human label for a bus topic, with the `ticket.<id>.` scope removed.

  Known topics get a written-out name so a 120px key reads as English rather
  than as a routing key; anything else degrades to its own segments, which is
  still more informative than the raw dotted string and never blank.
  """
  @spec topic_label(String.t() | nil) :: String.t()
  def topic_label(topic) when is_binary(topic) and topic != "" do
    scoped = strip_scope(topic)

    case Map.fetch(@topic_labels, scoped) do
      {:ok, label} -> label
      :error -> humanize_topic(scoped)
    end
  end

  def topic_label(_topic), do: "Event"

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

  def badge(role) when is_binary(role) and role in ["command", "tool", "user", "assistant", "system", "reasoning", "alert"],
    do: role |> role_atom() |> badge()

  # A persisted role can outlive the currently-known provider vocabulary.
  # Preserve that event in the Stream Deck feed with the neutral category
  # instead of misclassifying it as a system lifecycle event.
  def badge(_role), do: "INFO"

  defp entry(%{"role" => role, "payload" => payload} = event) when is_map(payload) do
    badge = badge(role)
    role = role_atom(role)
    if role == :tool, do: diff_entry(event, payload), else: message_entry(event, role, badge, tool_name(payload))
  end

  defp entry(%{"role" => role} = event), do: message_entry(event, role_atom(role), badge(role), nil)
  defp entry(_event), do: %{type: "message", badge: "INFO", role: "system", body: ""}

  # The provider's own tool name, so the renderer can pick a glyph and a title
  # instead of labelling every tool call generically.
  defp tool_name(payload) do
    case Map.get(payload, "tool") || Map.get(payload, :tool) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp diff_entry(event, %{"tool" => "edit", "changes" => changes} = payload) when is_list(changes) do
    Enum.find_value(changes, &provider_diff_entry(event, &1)) || message_entry(event, :tool, nil, tool_name(payload))
  end

  defp diff_entry(event, payload), do: message_entry(event, :tool, nil, tool_name(payload))

  defp provider_diff_entry(event, %{"diff" => output} = change) when is_binary(output) and output != "" do
    diff_entry(event, output, non_empty_path(Map.get(change, "path")))
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
      # A tool's display body is not structured file metadata. Keep the path
      # absent when neither the provider change nor its unified diff supplies
      # one instead of misrepresenting text such as "edit Foo" as a path.
      path: path || diff_path(output),
      additions: changed_line_count(output, "+"),
      deletions: changed_line_count(output, "-"),
      line: changed_line(output),
      lines: diff_lines(output)
    }
  end

  defp message_entry(event, role, badge, tool) do
    %{
      type: "message",
      badge: badge || badge(role),
      role: Atom.to_string(role),
      body: Map.get(event, "body", ""),
      tool: tool,
      timestamp: Map.get(event, "timestamp"),
      msg_id: Map.get(event, "msg_id"),
      turn_id: Map.get(event, "turn_id")
    }
  end

  # `event_history/2` answers a bare identifier with a plain list and a tracker
  # identity with a result tuple. Both shapes reach here, and neither an
  # unreadable log nor a missing one is an error worth propagating: a ticket
  # that has published nothing is an ordinary state.
  defp history_rows(rows) when is_list(rows), do: rows
  defp history_rows({:ok, rows}) when is_list(rows), do: rows
  defp history_rows(_other), do: []

  defp bus_entry(row) do
    kind = to_string(Map.get(row, :kind, "emit"))

    %{
      type: "event",
      id: Map.get(row, :id),
      kind: kind,
      topic: Map.get(row, :topic),
      badge: badge_for_kind(kind),
      label: topic_label(Map.get(row, :topic)),
      body: row |> Map.get(:summary, "") |> to_string() |> scrub() |> String.trim(),
      timestamp: Map.get(row, :ts)
    }
  end

  @doc """
  Drops any byte that is not valid UTF-8.

  `summarize/1` now slices by graphemes, so nothing new can be written badly —
  but a log written by an older build is already on disk, and this is the read
  side. An invalid byte here does not merely render oddly: `Jason` raises
  `EncodeError` on it, Phoenix's serializer calls `encode_to_iodata!/1` from the
  **socket transport** process, and the raise therefore tears down the whole
  Stream Deck socket — grid, usage and logs together. The sidecar reconnects,
  re-reads the same durable line, and dies again, so a single bad byte is a
  permanent outage that survives restarting both ends.
  """
  @spec scrub(String.t()) :: String.t()
  def scrub(value) when is_binary(value) do
    if String.valid?(value), do: value, else: scrub_bytes(value, "")
  end

  defp scrub_bytes(<<>>, acc), do: acc
  defp scrub_bytes(<<char::utf8, rest::binary>>, acc), do: scrub_bytes(rest, acc <> <<char::utf8>>)
  defp scrub_bytes(<<_byte, rest::binary>>, acc), do: scrub_bytes(rest, acc)

  @doc """
  Direction badge for a bus marker kind.

  Direction comes from the kind, which is exactly what the kind records: who
  moved the event. Deriving it from the topic instead would make the same
  `pr.merged` topic read as EMIT when this side published it and CONSUME when it
  arrived — the badge would then describe the subject rather than the direction,
  which is the one thing it is for.
  """
  @spec badge_for_kind(String.t() | atom()) :: String.t()
  def badge_for_kind(kind) when is_atom(kind), do: kind |> Atom.to_string() |> badge_for_kind()
  def badge_for_kind("consumed"), do: "CONSUME"
  def badge_for_kind("emit_alert"), do: "SYSTEM"
  def badge_for_kind("self"), do: "AGENT"
  def badge_for_kind(_kind), do: "EMIT"

  defp strip_scope("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [_id, scoped] -> scoped
      _ -> rest
    end
  end

  defp strip_scope("system." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [_scope, scoped] -> scoped
      _ -> rest
    end
  end

  defp strip_scope(topic), do: topic

  defp humanize_topic(scoped) do
    scoped
    |> String.split(".")
    |> Enum.map_join(" ", &String.replace(&1, "_", " "))
    |> String.trim()
    |> upcase_first()
  end

  defp upcase_first(""), do: "Event"
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

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

  defp non_empty_path(path) when is_binary(path) and path != "", do: path
  defp non_empty_path(_path), do: nil

  defp diff_path(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(fn
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

  # Real hunk lines, not just the first changed one.
  #
  # The Stream Deck's bottom panel renders an actual unified diff, so it needs
  # the lines themselves. File and hunk headers are dropped: `+++`/`---` are
  # already expressed by the entry's `path`, and an `@@` header costs a row of a
  # five-row panel to say something the surrounding rows already show. The
  # window is bounded here rather than at the renderer because an unbounded
  # provider diff has no business crossing the channel in the first place.
  defp diff_lines(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&header_line?/1)
    |> Enum.map(&diff_line/1)
    |> Enum.reject(&(&1.text == "" and &1.sign == " "))
    |> Enum.take(@max_diff_lines)
  end

  defp header_line?("+++" <> _rest), do: true
  defp header_line?("---" <> _rest), do: true
  defp header_line?("@@" <> _rest), do: true
  defp header_line?("diff --git" <> _rest), do: true
  defp header_line?("index " <> _rest), do: true
  defp header_line?(_line), do: false

  defp diff_line("+" <> text), do: %{sign: "+", text: trim_trailing(text)}
  defp diff_line("-" <> text), do: %{sign: "-", text: trim_trailing(text)}
  defp diff_line(" " <> text), do: %{sign: " ", text: trim_trailing(text)}
  defp diff_line(text), do: %{sign: " ", text: trim_trailing(text)}

  defp trim_trailing(text), do: text |> String.replace(~r/\R/u, " ") |> String.trim_trailing()

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
