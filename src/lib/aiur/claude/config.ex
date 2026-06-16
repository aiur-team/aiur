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
  Permission mode sent on `thread/start`. One of `default`, `acceptEdits`,
  or `bypassPermissions`. Defaults to `bypassPermissions` so the agent loop
  runs without interactive approvals; set a stricter mode to gate edits.
  """
  @spec permission_mode() :: String.t()
  def permission_mode do
    case section_value("permission_mode") do
      value when value in @valid_permission_modes -> value
      _ -> @default_permission_mode
    end
  end

  @impl Aiur.AgentConfig
  def validate! do
    if byte_size(String.trim(command())) > 0 do
      :ok
    else
      {:error, "Claude command missing — set claude.command in .aiurconfig"}
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
    Aiur.Config.settings!().agent.claude
    |> Map.from_struct()
    |> Map.get(String.to_existing_atom(key))
  end
end
