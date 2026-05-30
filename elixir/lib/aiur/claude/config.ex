defmodule Aiur.Claude.Config do
  @moduledoc """
  Claude-specific configuration read from the `claude:` YAML section.
  """

  @behaviour Aiur.AgentConfig

  @default_command "aiur-claude"

  @spec command() :: String.t()
  def command do
    case section_value("command") do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @default_command
    end
  end

  @doc """
  Model the app-server passes to `claude --model`. Returns nil when
  unset so the turn omits the field and the app-server picks its default.
  """
  @spec model() :: String.t() | nil
  def model, do: trimmed_section_value("model")

  @doc """
  Human-facing model version label (e.g. `opus-4-8`). Recorded in config
  for operator visibility; not sent on the wire unless also set as `model`.
  """
  @spec version() :: String.t() | nil
  def version, do: trimmed_section_value("version")

  @impl Aiur.AgentConfig
  def validate! do
    if byte_size(String.trim(command())) > 0 do
      :ok
    else
      {:error, "Claude command missing — set claude.command in WORKFLOW.md"}
    end
  end

  defp trimmed_section_value(key) do
    case section_value(key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp section_value(key) do
    Map.get(Aiur.Config.section("claude"), key)
  end
end
