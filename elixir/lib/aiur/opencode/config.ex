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
    case section_value("bridge_host") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: @default_bridge_host, else: value

      _ ->
        @default_bridge_host
    end
  end

  @spec bridge_port() :: non_neg_integer()
  def bridge_port do
    case section_value("bridge_port") do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_bridge_port
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
        {:error, "opencode.command is blank - set opencode.command in WORKFLOW.md"}

      is_nil(System.find_executable(executable)) ->
        {:error, "opencode command #{inspect(executable)} was not found on PATH - install opencode or set opencode.command in WORKFLOW.md"}

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

  defp section_value(key), do: Map.get(Aiur.Config.section("opencode"), key)
end
