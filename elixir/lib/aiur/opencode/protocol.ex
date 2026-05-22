defmodule Aiur.Opencode.Protocol do
  @moduledoc """
  Isolation boundary for opencode-specific wire/config shapes.
  """

  alias Aiur.Opencode.Config

  @verified_min "0.7.0"
  @verified_max "0.7.x"

  @event_session_idle "session.idle"
  @event_session_error "session.error"
  @event_permission_asked "permission.asked"
  @event_tool_before "tool.execute.before"
  @event_tool_after "tool.execute.after"

  @spec verified_min() :: String.t()
  def verified_min, do: @verified_min

  @spec verified_max() :: String.t()
  def verified_max, do: @verified_max

  @spec session_idle() :: String.t()
  def session_idle, do: @event_session_idle

  @spec session_error() :: String.t()
  def session_error, do: @event_session_error

  @spec permission_asked() :: String.t()
  def permission_asked, do: @event_permission_asked

  @spec tool_before() :: String.t()
  def tool_before, do: @event_tool_before

  @spec tool_after() :: String.t()
  def tool_after, do: @event_tool_after

  @spec user_message_part(String.t()) :: map()
  def user_message_part(text), do: %{role: "user", parts: [%{type: "text", text: text}]}

  @spec assistant_text_message(String.t()) :: map()
  def assistant_text_message(text), do: %{role: "assistant", parts: [%{type: "text", text: text}]}

  @spec assistant_command_message(String.t(), String.t(), map() | keyword()) :: map()
  def assistant_command_message(command, output, opts \\ []) do
    %{
      role: "assistant",
      parts: [
        %{type: "tool_call", name: "bash", input: %{command: command}},
        %{type: "tool_result", output: output, output_meta: Map.new(opts)}
      ]
    }
  end

  @spec system_message_part(String.t()) :: map()
  def system_message_part(body), do: assistant_text_message("**system:** " <> body)

  @spec alert_message_part(String.t()) :: map()
  def alert_message_part(body), do: assistant_text_message("**alert:** " <> body)

  @spec opencode_json(map()) :: map()
  def opencode_json(
        %{
          bridge_url: bridge_url,
          bridge_token: bridge_token,
          identifier: identifier
        } = attrs
      ) do
    safe_id = Config.safe_identifier(identifier)
    model_prefix = Map.get(attrs, :model_prefix, Config.model_prefix())

    # `:extra_identifiers` lets the caller declare additional agent
    # identifiers in the same provider config. opencode's TUI shows
    # `Model not found: <id>. Did you mean: <other_id>?` when a session's
    # model isn't declared — and that error LEAKS the warm-server's
    # `_warm` identifier into the visible chat pane (R6 violation). To
    # avoid that, the warm-server's opencode.json must declare every
    # agent identifier whose session will ever attach to it.
    extra = Map.get(attrs, :extra_identifiers, [])

    all_ids =
      [safe_id | Enum.map(extra, &Config.safe_identifier/1)]
      |> Enum.uniq()

    # Model name MUST match the identifier so opencode's chat chrome
    # reads `aiur · issue-13` instead of `Aiur · Aiur`. The provider
    # name (line below) stays as the human-facing label.
    models =
      Map.new(all_ids, fn id ->
        model_key = "issue-#{id}"
        {model_key, %{"name" => model_key}}
      end)

    %{
      "$schema" => "https://opencode.ai/config.json",
      "provider" => %{
        "aiur" => %{
          "npm" => "@ai-sdk/openai-compatible",
          "name" => "Aiur",
          "options" => %{
            "baseURL" => bridge_url <> "/v1",
            "apiKey" => bridge_token
          },
          "models" => models
        }
      },
      "model" => "#{model_prefix}/issue-#{safe_id}",
      "permission" => %{
        "edit" => "deny",
        "bash" => "deny",
        "webfetch" => "deny"
      }
    }
  end

  # Aiur ships a custom theme that explicitly sets every background to "none" — the built-in
  # "none" theme still paints message-box surfaces. The matching theme JSON lives in
  # `<workspace>/.opencode/themes/aiur.json` (see `WorkspaceSetup`).
  @spec tui_json() :: map()
  def tui_json do
    %{
      "$schema" => "https://opencode.ai/tui.json",
      "theme" => "aiur"
    }
  end

  # Custom theme: every `*Bg` / background-* key set to "none" so the host terminal's
  # background and palette show through; distinct accent colors so user vs agent reads
  # apart even without a panel fill.
  @spec aiur_theme_json() :: map()
  def aiur_theme_json do
    %{
      "$schema" => "https://opencode.ai/theme.json",
      "theme" => %{
        "primary" => %{"dark" => 14, "light" => 6},
        "secondary" => %{"dark" => 13, "light" => 5},
        "accent" => %{"dark" => 11, "light" => 3},
        "error" => %{"dark" => 9, "light" => 1},
        "warning" => %{"dark" => 11, "light" => 3},
        "success" => %{"dark" => 10, "light" => 2},
        "info" => %{"dark" => 12, "light" => 4},
        "text" => "none",
        "textMuted" => %{"dark" => 8, "light" => 7},
        "background" => "none",
        "backgroundPanel" => "none",
        "backgroundElement" => "none",
        "border" => %{"dark" => 8, "light" => 7},
        "borderActive" => %{"dark" => 14, "light" => 6},
        "borderSubtle" => %{"dark" => 8, "light" => 7},
        "diffAdded" => %{"dark" => 10, "light" => 2},
        "diffRemoved" => %{"dark" => 9, "light" => 1},
        "diffContext" => "none",
        "diffHunkHeader" => %{"dark" => 14, "light" => 6},
        "diffHighlightAdded" => %{"dark" => 10, "light" => 2},
        "diffHighlightRemoved" => %{"dark" => 9, "light" => 1},
        "diffAddedBg" => "none",
        "diffRemovedBg" => "none",
        "diffContextBg" => "none",
        "diffLineNumber" => %{"dark" => 8, "light" => 7},
        "diffAddedLineNumberBg" => "none",
        "diffRemovedLineNumberBg" => "none",
        "markdownText" => "none",
        "markdownHeading" => %{"dark" => 14, "light" => 6},
        "markdownLink" => %{"dark" => 12, "light" => 4},
        "markdownLinkText" => %{"dark" => 14, "light" => 6},
        "markdownCode" => %{"dark" => 10, "light" => 2},
        "markdownBlockQuote" => %{"dark" => 8, "light" => 7},
        "markdownEmph" => %{"dark" => 13, "light" => 5},
        "markdownStrong" => %{"dark" => 11, "light" => 3},
        "markdownHorizontalRule" => %{"dark" => 8, "light" => 7},
        "markdownListItem" => %{"dark" => 14, "light" => 6},
        "markdownListEnumeration" => %{"dark" => 12, "light" => 4},
        "markdownImage" => %{"dark" => 12, "light" => 4},
        "markdownImageText" => %{"dark" => 14, "light" => 6},
        "markdownCodeBlock" => "none",
        "syntaxComment" => %{"dark" => 8, "light" => 7},
        "syntaxKeyword" => %{"dark" => 13, "light" => 5},
        "syntaxFunction" => %{"dark" => 12, "light" => 4},
        "syntaxVariable" => %{"dark" => 14, "light" => 6},
        "syntaxString" => %{"dark" => 10, "light" => 2},
        "syntaxNumber" => %{"dark" => 11, "light" => 3},
        "syntaxType" => %{"dark" => 14, "light" => 6},
        "syntaxOperator" => %{"dark" => 13, "light" => 5},
        "syntaxPunctuation" => "none"
      }
    }
  end

  # opencode.json has `additionalProperties: false`; reap-path metadata lives in a sidecar file instead.
  @spec aiur_metadata(map()) :: map()
  def aiur_metadata(%{identifier: identifier} = attrs) do
    %{
      "identifier" => identifier,
      "opencode_os_pid" => Map.get(attrs, :opencode_os_pid)
    }
  end

  # ---------------------------------------------------------------- SQLite row JSON
  #
  # Builders for the `message.data` and `part.data` JSON columns in
  # opencode's SQLite store. Shapes verified against opencode 1.15.6 — see
  # `elixir/docs/notes/opencode-row-shapes-1.15.6.md`.
  #
  # The `id`, `session_id`, and `message_id` fields the OpenAPI schema
  # demands are NOT stored in `data` — they live in SQL columns. These
  # builders return only the JSON-encoded payload.

  @doc """
  Synthetic user message row used as the parent of replayed assistant
  messages and as the synthetic-stream marker carrier for live updates.

  `opts[:marker]` switches between the two shapes:
    * `:replay_root` (default) — invisible parent for history replay.
    * `{:stream, message_id}` — synthetic user message whose text part
      carries the `__aiur_stream__:<msg_id>` marker for the bridge to
      recognise and stream back as an assistant reply.
  """
  @spec user_message_data(String.t(), keyword()) :: map()
  def user_message_data(identifier, opts \\ []) when is_binary(identifier) do
    now_ms = System.os_time(:millisecond)
    safe_id = Config.safe_identifier(identifier)

    %{
      "role" => "user",
      "time" => %{"created" => now_ms},
      "agent" => "build",
      "model" => %{"providerID" => "aiur", "modelID" => "issue-#{safe_id}"},
      "summary" => %{"diffs" => []}
    }
    |> maybe_put_marker(opts[:marker])
  end

  defp maybe_put_marker(map, nil), do: map
  defp maybe_put_marker(map, :replay_root), do: map
  defp maybe_put_marker(map, {:stream, _msg_id}), do: map

  @doc """
  Assistant message row JSON. Required fields per
  opencode's `AssistantMessage` schema:

    * `role: "assistant"`
    * `parentID` — must match `^msg`
    * `modelID`, `providerID` (`aiur` for our rows)
    * `mode`, `agent` — both `"build"` for normal flows
    * `path` — opencode sidebar uses these
    * `cost`, `tokens` — zeros for Aiur-injected rows
    * `time: {created, completed}`
    * `finish` — `"stop"` or `"tool-calls"`

  `attrs` keys: `identifier`, `parent_id`, `cwd`, optional `finish`.
  """
  @spec assistant_message_data(map()) :: map()
  def assistant_message_data(%{identifier: identifier, parent_id: parent_id} = attrs) do
    now_ms = System.os_time(:millisecond)
    safe_id = Config.safe_identifier(identifier)
    cwd = Map.get(attrs, :cwd, "/")
    finish = Map.get(attrs, :finish, "stop")

    %{
      "parentID" => parent_id,
      "role" => "assistant",
      "mode" => "build",
      "agent" => "build",
      "path" => %{"cwd" => cwd, "root" => "/"},
      "cost" => 0,
      "tokens" => %{
        "total" => 0,
        "input" => 0,
        "output" => 0,
        "reasoning" => 0,
        "cache" => %{"write" => 0, "read" => 0}
      },
      "modelID" => "issue-#{safe_id}",
      "providerID" => "aiur",
      "time" => %{"created" => now_ms, "completed" => now_ms},
      "finish" => finish
    }
  end

  @doc """
  Plain text part data. `opts[:synthetic]` marks the part synthetic so
  opencode's TUI styles it differently (or hides it, depending on theme).
  """
  @spec text_part_data(String.t(), keyword()) :: map()
  def text_part_data(text, opts \\ []) when is_binary(text) do
    base = %{"type" => "text", "text" => text}

    if Keyword.get(opts, :synthetic, false) do
      Map.put(base, "synthetic", true)
    else
      base
    end
  end

  @doc """
  Tool part data — represents a single completed tool call + result.
  Use for command transcript events (bash invocations + output).

  `opts` keys: `tool` (default `"bash"`), `input` (map), `output`
  (string), `title` (string), `call_id`.
  """
  @spec tool_part_data(keyword()) :: map()
  def tool_part_data(opts) when is_list(opts) do
    now_ms = System.os_time(:millisecond)

    %{
      "type" => "tool",
      "tool" => Keyword.get(opts, :tool, "bash"),
      "callID" => Keyword.get(opts, :call_id, "call_synthetic"),
      "state" => %{
        "status" => "completed",
        "input" => Keyword.get(opts, :input, %{}),
        "output" => Keyword.get(opts, :output, ""),
        "metadata" => Keyword.get(opts, :metadata, %{}),
        "title" => Keyword.get(opts, :title, ""),
        "time" => %{"start" => now_ms, "end" => now_ms}
      }
    }
  end

  @doc """
  Step-start part — opencode wraps each assistant turn with a step-start
  and a step-finish marker. Required for the assistant message's
  rendering to match a real codex turn.
  """
  @spec step_start_part_data() :: map()
  def step_start_part_data, do: %{"type" => "step-start"}

  @doc """
  Step-finish part — paired with `step_start_part_data/0`. `reason`
  defaults to `"stop"`; pass `"tool-calls"` when the assistant message
  also contains a tool part.
  """
  @spec step_finish_part_data(keyword()) :: map()
  def step_finish_part_data(opts \\ []) do
    %{
      "type" => "step-finish",
      "reason" => Keyword.get(opts, :reason, "stop"),
      "cost" => 0,
      "tokens" => %{
        "total" => 0,
        "input" => 0,
        "output" => 0,
        "reasoning" => 0,
        "cache" => %{"write" => 0, "read" => 0}
      }
    }
  end

  @doc """
  Predicate used by Aiur to identify the opencode sessions it owns —
  matches on `model.providerID == "aiur"`. Drives both shutdown cleanup
  and boot-time GC of leftover sessions from prior crashes.
  """
  @spec aiur_owned?(map() | nil) :: boolean()
  def aiur_owned?(%{"providerID" => "aiur"}), do: true
  def aiur_owned?(%{providerID: "aiur"}), do: true
  def aiur_owned?(_), do: false

  @spec serve_command(non_neg_integer(), String.t(), [String.t()]) :: String.t()
  def serve_command(port, host, extra_args \\ []) do
    Enum.map_join(
      [Config.command(), "serve", "--port", to_string(port), "--hostname", host] ++ extra_args,
      " ",
      &shell_escape/1
    )
  end

  @spec attach_command(String.t(), String.t()) :: String.t()
  def attach_command(url, session_id) when is_binary(session_id) do
    Enum.map_join(
      [Config.command(), "attach", url, "--session", session_id],
      " ",
      &shell_escape/1
    )
  end

  @doc """
  Build an `opencode attach <url>` command without a `--session` arg.
  Used by slot workers when the opencode-attach process should start
  in the hidden window with no session selected; the slot calls
  `/tui/select-session` later when a user opens that slot's pane.
  """
  @spec attach_command(String.t()) :: String.t()
  def attach_command(url) do
    Enum.map_join([Config.command(), "attach", url], " ", &shell_escape/1)
  end

  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9_\/:.,=@%+-]+$/) do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end
end
