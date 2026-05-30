defmodule Aiur.Claude.Config do
  @moduledoc """
  Claude-specific configuration read from the `claude:` YAML section.
  """

  @behaviour Aiur.AgentConfig

  @default_command "aiur-claude"
  @default_permission_mode "bypassPermissions"
  @valid_permission_modes ~w(default acceptEdits bypassPermissions)

  @spec command() :: String.t()
  def command do
    case section_value("command") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_command
          trimmed -> trimmed
        end

      _ ->
        @default_command
    end
  end

  @doc """
  Per-turn Claude model identifier. Returns `nil` when the workflow does
  not set one — claude-app-server then picks its own default. Available
  models come from `model/list` (e.g. `claude-opus-4-6`, `claude-sonnet-4-6`,
  `claude-haiku-4-5`).
  """
  @spec model() :: String.t() | nil
  def model do
    case section_value("model") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Stored verbatim. Not part of the wire protocol today; reserved for
  future use (e.g. pinning claude-app-server compatibility).
  """
  @spec version() :: String.t() | nil
  def version do
    case section_value("version") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @spec permission_mode() :: String.t()
  def permission_mode do
    case section_value("permission_mode") do
      value when value in @valid_permission_modes -> value
      _ -> @default_permission_mode
    end
  end

  @spec runtime_settings() :: %{
          model: String.t() | nil,
          version: String.t() | nil,
          permission_mode: String.t()
        }
  def runtime_settings do
    %{
      model: model(),
      version: version(),
      permission_mode: permission_mode()
    }
  end

  @impl Aiur.AgentConfig
  def validate! do
    cond do
      byte_size(String.trim(command())) == 0 ->
        {:error, "Claude command missing — set claude.command in WORKFLOW.md"}

      permission_mode() not in @valid_permission_modes ->
        {:error,
         "Invalid claude.permission_mode in WORKFLOW.md — must be one of #{inspect(@valid_permission_modes)}"}

      true ->
        :ok
    end
  end

  defp section_value(key) do
    Map.get(Aiur.Config.section("claude"), key)
  end
end
