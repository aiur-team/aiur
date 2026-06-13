defmodule Aiur.Claude.HookEvents do
  @moduledoc """
  Ingest and fan-out for Claude Code lifecycle hooks — the RC-claude turn signal.

  The `claude-repl` backend runs interactive `claude --remote-control`, which emits
  no structured stdout, so aiur cannot read turn boundaries from a pipe. claude
  v2.1.177 also flushes its `~/.claude/projects/*.jsonl` transcript lazily, so the
  old transcript-poll (`Aiur.Claude.ReplAgent.await_transcript/2`) times out
  `:no_transcript` on every cold-start turn and the agent gives up.

  Instead we configure claude hooks (via `--settings`, see
  `Aiur.Claude.HookSettings`) whose command POSTs the event JSON to the dashboard
  (`POST /api/v1/<identifier>/claude-hook`). This module normalizes each event and
  broadcasts it on a per-agent `Phoenix.PubSub` topic that the agent's `run_turn`
  process subscribes to:

    * `UserPromptSubmit` — claude accepted input (turn start / operator-message receipt)
    * `PostToolUse`      — a tool finished (live progress + liveness heartbeat)
    * `Stop`             — the turn completed; carries `last_assistant_message`

  A hook POST must never fail claude, so `dispatch/2` always returns `:ok`.
  """

  require Logger

  @pubsub Aiur.PubSub

  @type kind :: :user_prompt_submit | :post_tool_use | :stop | :unknown

  @type event :: %{
          event: kind(),
          session_id: String.t() | nil,
          cwd: String.t() | nil,
          prompt: String.t() | nil,
          message: String.t() | nil,
          tool_name: String.t() | nil,
          raw: map()
        }

  @spec topic(String.t()) :: String.t()
  def topic(identifier) when is_binary(identifier), do: "claude_hook:" <> identifier

  @doc "Subscribe the calling process to an agent's hook-event topic."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(identifier) when is_binary(identifier) do
    Phoenix.PubSub.subscribe(@pubsub, topic(identifier))
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(identifier) when is_binary(identifier) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(identifier))
  end

  @doc """
  Normalize a raw hook payload and broadcast `{:claude_hook, identifier, event}` on
  the agent topic. Always `:ok` — never raises, so a hook POST cannot disrupt claude.
  """
  @spec dispatch(String.t(), map()) :: :ok
  def dispatch(identifier, raw) when is_binary(identifier) and is_map(raw) do
    event = normalize(raw)

    Logger.info(
      "claude_hook identifier=#{identifier} event=#{event.event} session=#{event.session_id || "?"} " <>
        "tool=#{event.tool_name || "-"} bytes=#{byte_size(event.message || event.prompt || "")}"
    )

    do_broadcast(topic(identifier), {:claude_hook, identifier, event})
  end

  def dispatch(_identifier, _raw), do: :ok

  @doc "Map a raw claude hook payload to the normalized `event/0` shape."
  @spec normalize(map()) :: event()
  def normalize(raw) when is_map(raw) do
    %{
      event: classify(Map.get(raw, "hook_event_name")),
      session_id: string_or_nil(Map.get(raw, "session_id")),
      cwd: string_or_nil(Map.get(raw, "cwd")),
      prompt: string_or_nil(Map.get(raw, "prompt")),
      message: string_or_nil(Map.get(raw, "last_assistant_message")),
      tool_name: string_or_nil(Map.get(raw, "tool_name")),
      raw: raw
    }
  end

  defp classify("UserPromptSubmit"), do: :user_prompt_submit
  defp classify("PostToolUse"), do: :post_tool_use
  defp classify("Stop"), do: :stop
  defp classify(_), do: :unknown

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  # Defensive guard mirrors AgentPubSub: producers must not crash if the PubSub
  # registry is absent (early boot / test teardown).
  defp do_broadcast(topic, message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.broadcast(@pubsub, topic, message)
      _ -> :ok
    end
  end
end
