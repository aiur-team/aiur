defmodule Aiur.Listener.HookEnvelope do
  @moduledoc "Pure, bounded operator-message frames and Claude-style hook envelopes for Claude and Codex."

  alias Aiur.Listener.HookFrame

  # DESIGN-E7 / listener-mode §8: operator messages are instructions; shared fixtures are copy-neutral.
  @intro "The following messages are instructions from your Aiur operator."
  @tag "aiur-operator-messages"

  @doc "Render already-selected hook deliveries. Scheduling and continuation suppression belong to the caller."
  @spec render(atom() | String.t(), atom() | String.t() | nil, [map()], keyword()) :: {:ok, String.t(), pos_integer()} | :none
  def render(harness, event, entries, opts \\ []) do
    if supported?(harness, event) and Keyword.get(opts, :mode, :sync) not in [:async, :mute, "async", "mute"] do
      with {:ok, frame, count} <- HookFrame.render(Stream.map(entries, &entry/1), &wrap/1),
           {:ok, output} <- envelope(harness, event, frame, opts) do
        {:ok, output, count}
      else
        _ -> :none
      end
    else
      :none
    end
  end

  @doc "Encode a copy-neutral frame using the shared hook codec, including its trailing newline."
  @spec envelope(atom() | String.t(), atom() | String.t() | nil, String.t(), keyword()) :: {:ok, String.t()} | :none
  def envelope(harness, event, frame, opts \\ []) do
    if supported?(harness, event) do
      name = event_name(event)
      context? = name != "Stop" or Keyword.get(opts, :stop_context, false)

      output =
        if context? do
          ~s({"hookSpecificOutput":{"hookEventName":#{Jason.encode!(name)},"additionalContext":#{Jason.encode!(frame)}}}\n)
        else
          ~s({"decision":"block","reason":#{Jason.encode!(frame)}}\n)
        end

      {:ok, output}
    else
      :none
    end
  end

  defp supported?(harness, event), do: harness in [:claude, :codex, "claude", "codex"] and event_name(event) != nil
  defp event_name(event) when event in [:tool, "tool", "PostToolUse"], do: "PostToolUse"
  defp event_name(event) when event in [:prompt, "prompt", "UserPromptSubmit"], do: "UserPromptSubmit"
  defp event_name(event) when event in [:stop, "stop", "Stop"], do: "Stop"
  defp event_name(_), do: nil

  defp wrap(lines), do: "<#{@tag} count=\"#{length(lines)}\">\n#{@intro}\n\n#{Enum.join(lines, "\n\n")}\n</#{@tag}>"

  defp entry(entry) do
    label = scrub(entry.sender_label)
    kind = scrub(entry.sender_kind)
    timestamp = scrub(entry.ts)
    id = scrub(entry.delivery_id)
    body = entry.body |> escape_tag() |> String.replace("\n", "\n  ")
    %{prefix: "[#{timestamp}] #{label} (#{kind}):\n  ", body: body, suffix: "\n[aiur:delivery #{id}]"}
  end

  defp scrub(value), do: value |> to_string() |> String.replace(~r/[\p{Cc}\p{Zl}\p{Zp}]/u, " ") |> escape_tag()
  defp escape_tag(value), do: String.replace(value, ~r/<(\/?aiur-operator-messages)/iu, "&lt;\\1")
end
