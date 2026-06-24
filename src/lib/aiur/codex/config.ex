defmodule Aiur.Codex.Config do
  @moduledoc """
  Codex-specific configuration read from the `codex:` YAML section.
  """

  @behaviour Aiur.AgentConfig

  @default_command "codex app-server"
  # codex app-server's `approvalPolicy` is an enum string, not a map. Sending
  # the old map default crashed the turn with `unknown variant`. `untrusted`
  # preserves the prior fail-closed default — only `never` auto-approves
  # (see `auto_approve_requests` in coding_agent.ex), so any other variant
  # surfaces approval requests instead of silently running them headlessly.
  @valid_approval_policies ~w(untrusted on-failure on-request granular never)
  @default_approval_policy "untrusted"
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
    Aiur.Config.codex_turn_sandbox_policy(workspace)
  rescue
    ArgumentError -> default_turn_sandbox_policy(workspace)
  end

  @spec runtime_settings(Path.t() | nil) :: {:ok, map()} | {:error, term()}
  def runtime_settings(workspace \\ nil) do
    Aiur.Config.codex_runtime_settings(workspace)
  end

  @impl Aiur.AgentConfig
  def validate! do
    with {:ok, _} <- runtime_settings() do
      if byte_size(String.trim(command())) > 0 do
        :ok
      else
        {:error, "Codex command missing — set codex.command in .aiurconfig"}
      end
    end
  end

  defp resolve_approval_policy do
    case section_value("approval_policy") do
      nil -> {:ok, @default_approval_policy}
      value -> validate_approval_policy(value)
    end
  end

  @doc false
  @spec validate_approval_policy(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_approval_policy(value) when is_binary(value) do
    case String.trim(value) do
      trimmed when trimmed in @valid_approval_policies -> {:ok, trimmed}
      _ -> {:error, invalid_approval_policy(value)}
    end
  end

  def validate_approval_policy(value), do: {:error, invalid_approval_policy(value)}

  defp invalid_approval_policy(value) do
    "Invalid codex.approval_policy #{inspect(value)} — must be one of: " <>
      Enum.join(@valid_approval_policies, ", ")
  end

  defp resolve_thread_sandbox do
    case section_value("thread_sandbox") do
      nil ->
        {:ok, @default_thread_sandbox}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "Invalid codex.thread_sandbox in .aiurconfig: #{inspect(value)}"}
          _trimmed -> {:ok, value}
        end

      value ->
        {:error, "Invalid codex.thread_sandbox in .aiurconfig: #{inspect(value)}"}
    end
  end

  defp default_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(Aiur.Config.workspace_root())
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
    Aiur.Config.settings!().agent.codex
    |> Map.from_struct()
    |> Map.get(String.to_existing_atom(key))
  end
end
