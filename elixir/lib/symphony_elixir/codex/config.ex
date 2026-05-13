defmodule SymphonyElixir.Codex.Config do
  @moduledoc """
  Codex-specific configuration read from the `codex:` YAML section.
  """

  @behaviour SymphonyElixir.AgentConfig

  @default_command "codex app-server"
  @default_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_thread_sandbox "workspace-write"

  @spec command() :: String.t()
  def command do
    case section_value("command") do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> @default_command
    end
  end

  @spec approval_policy() :: String.t() | map()
  def approval_policy do
    case resolve_approval_policy() do
      {:ok, value} -> value
      {:error, _} -> @default_approval_policy
    end
  end

  @spec thread_sandbox() :: String.t()
  def thread_sandbox do
    case resolve_thread_sandbox() do
      {:ok, value} -> value
      {:error, _} -> @default_thread_sandbox
    end
  end

  @spec turn_sandbox_policy(Path.t() | nil) :: map()
  def turn_sandbox_policy(workspace \\ nil) do
    case resolve_turn_sandbox_policy(workspace) do
      {:ok, value} -> value
      {:error, _} -> default_turn_sandbox_policy(workspace)
    end
  end

  @spec runtime_settings(Path.t() | nil) :: {:ok, map()} | {:error, term()}
  def runtime_settings(workspace \\ nil) do
    with {:ok, ap} <- resolve_approval_policy(),
         {:ok, ts} <- resolve_thread_sandbox(),
         {:ok, tsp} <- resolve_turn_sandbox_policy(workspace) do
      {:ok,
       %{
         approval_policy: ap,
         thread_sandbox: ts,
         turn_sandbox_policy: tsp
       }}
    end
  end

  @impl SymphonyElixir.AgentConfig
  def validate! do
    with {:ok, _} <- runtime_settings() do
      if byte_size(String.trim(command())) > 0 do
        :ok
      else
        {:error, "Codex command missing — set codex.command in WORKFLOW.md"}
      end
    end
  end

  defp resolve_approval_policy do
    case section_value("approval_policy") do
      nil ->
        {:ok, @default_approval_policy}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "Invalid codex.approval_policy in WORKFLOW.md: #{inspect(value)}"}
          _trimmed -> {:ok, value}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, "Invalid codex.approval_policy in WORKFLOW.md: #{inspect(value)}"}
    end
  end

  defp resolve_thread_sandbox do
    case section_value("thread_sandbox") do
      nil ->
        {:ok, @default_thread_sandbox}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "Invalid codex.thread_sandbox in WORKFLOW.md: #{inspect(value)}"}
          _trimmed -> {:ok, value}
        end

      value ->
        {:error, "Invalid codex.thread_sandbox in WORKFLOW.md: #{inspect(value)}"}
    end
  end

  defp resolve_turn_sandbox_policy(workspace) do
    case section_value("turn_sandbox_policy") do
      nil ->
        {:ok, default_turn_sandbox_policy(workspace)}

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, "Invalid codex.turn_sandbox_policy in WORKFLOW.md: #{inspect(value)}"}
    end
  end

  defp default_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(SymphonyElixir.Config.workspace_root())
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp section_value(key) do
    Map.get(SymphonyElixir.Config.section("codex"), key)
  end
end
