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
          "models" => %{
            "issue-#{safe_id}" => %{
              "name" => "Aiur #{identifier}"
            }
          }
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

  @spec serve_command(non_neg_integer(), String.t(), [String.t()]) :: String.t()
  def serve_command(port, host, extra_args \\ []) do
    ([Config.command(), "serve", "--port", to_string(port), "--hostname", host] ++ extra_args)
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
  end

  @spec attach_command(String.t(), String.t()) :: String.t()
  def attach_command(url, session_id) do
    [Config.command(), "attach", url, "--session", session_id]
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
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
