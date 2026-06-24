defmodule Aiur.Opencode.Config do
  @moduledoc """
  opencode-specific configuration read from the `opencode:` YAML section.
  """

  @behaviour Aiur.AgentConfig

  @default_command "opencode"
  @default_bridge_host "127.0.0.1"
  @default_bridge_port 4097
  @default_model_prefix "aiur"

  @spec command() :: String.t()
  def command do
    case section_value("command") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: @default_command, else: value

      _ ->
        @default_command
    end
  end

  @spec bridge_host() :: String.t()
  def bridge_host do
    case Application.get_env(:aiur, :opencode_bridge_host_override) || section_value("bridge_host") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: @default_bridge_host, else: value

      _ ->
        @default_bridge_host
    end
  end

  @spec bridge_port() :: non_neg_integer()
  def bridge_port do
    case Application.get_env(:aiur, :opencode_bridge_port_override) ||
           env_bridge_port() ||
           section_value("bridge_port") do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_bridge_port
    end
  end

  defp env_bridge_port do
    case System.get_env("AIUR_OPENCODE_BRIDGE_PORT") do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {port, ""} when port >= 0 and port < 65_536 -> port
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec serve_args() :: [String.t()]
  def serve_args do
    case section_value("serve_args") do
      value when is_list(value) -> Enum.map(value, &to_string/1)
      _ -> []
    end
  end

  @spec model_prefix() :: String.t()
  def model_prefix do
    case section_value("model_prefix") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: @default_model_prefix, else: value

      _ ->
        @default_model_prefix
    end
  end

  @spec model_for_issue(String.t()) :: String.t()
  def model_for_issue(identifier) when is_binary(identifier) do
    "#{model_prefix()}/issue-#{safe_identifier(identifier)}"
  end

  @impl Aiur.AgentConfig
  def validate! do
    command = command()
    executable = command |> String.split() |> List.first()

    cond do
      not is_binary(executable) or executable == "" ->
        {:error, "opencode.command is blank - set opencode.command in .aiurconfig"}

      is_nil(System.find_executable(executable)) ->
        {:error, "opencode command #{inspect(executable)} was not found on PATH - install opencode or set opencode.command in .aiurconfig"}

      true ->
        :ok
    end
  end

  @spec safe_identifier(String.t() | nil) :: String.t()
  def safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  @spec db_path() :: String.t() | nil
  def db_path do
    case section_value("db_path") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  @doc """
  Path used as the cwd of the warm `opencode serve`. Defaults to
  `~/.local/share/aiur/opencode-warm`. Override via the workflow's
  `opencode.prewarm_workspace` setting.
  """
  @spec prewarm_workspace() :: String.t()
  def prewarm_workspace do
    case section_value("prewarm_workspace") do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          default_prewarm_workspace()
        else
          Path.expand(value)
        end

      _ ->
        default_prewarm_workspace()
    end
  end

  defp default_prewarm_workspace do
    Path.join([System.user_home!(), ".local/share/aiur/opencode-warm"])
  end

  @doc """
  Returns true when pre-warm should be skipped — workflow override or
  `AIUR_PREWARM_DISABLED=1` env var. Lets users opt out without code
  changes (e.g. on tmux <3.0 where `join-pane` semantics may differ).
  """
  @spec prewarm_disabled?() :: boolean()
  def prewarm_disabled? do
    cond do
      section_value("prewarm_disabled") == true -> true
      System.get_env("AIUR_PREWARM_DISABLED") in ["1", "true", "yes"] -> true
      true -> false
    end
  end

  # An unknown key (no matching schema field) reads as "unset" rather than
  # crashing the interactive boot via String.to_existing_atom/1.
  defp section_value(key) do
    Aiur.Config.settings!().opencode
    |> Map.from_struct()
    |> Map.get(String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
