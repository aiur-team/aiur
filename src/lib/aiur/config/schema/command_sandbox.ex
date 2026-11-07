defmodule Aiur.Config.Schema.CommandSandbox do
  @moduledoc """
  Validation for `agent.backend_configs.<backend>.command_sandbox`, the extra
  mounts and `PATH` entries for the bubblewrap sandbox that runs
  `exec_command` on OpenAI-compatible backends.
  """

  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.command_sandbox.read_only_binds | array of absolute paths | `[]` | Host paths bound read-only at the same path inside the `exec_command` sandbox of an OpenAI-compatible backend. Missing paths are skipped. Refused at load: a relative path, a `..` segment, `/`, the operator home, and anything under `~/.aiur`. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.command_sandbox.writable_binds | array of absolute paths | `[]` | Host paths bound writable at the same path inside the `exec_command` sandbox, for a cache outside the workspace. Same path rules and missing-path behavior as `read_only_binds`. |
  # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
  # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.command_sandbox.path | array of absolute paths | `[]` | Directories added to the sandbox `PATH` (for example the directory holding `node`). Each entry is also bound read-only so it is reachable. Same path rules as `read_only_binds`. `/etc/alternatives` is always bound read-only when it exists. |

  @fields ~w(read_only_binds writable_binds path)

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok

  def validate(%{} = section) do
    section = Map.new(section, fn {key, value} -> {to_string(key), value} end)

    with :ok <- reject_unknown(section) do
      Enum.find_value(@fields, :ok, &list_error(&1, Map.get(section, &1)))
    end
  end

  defp list_error(field, value) do
    case validate_list(field, value) do
      :ok -> nil
      error -> error
    end
  end

  def validate(_other), do: {:error, "command_sandbox must be a map"}

  @doc "Validates the `command_sandbox` section of one backend config, if present."
  @spec validate_backend(term()) :: :ok | {:error, String.t()}
  def validate_backend(%{} = config), do: validate(Map.get(config, "command_sandbox", Map.get(config, :command_sandbox)))
  def validate_backend(_config), do: :ok

  defp reject_unknown(section) do
    case Map.keys(section) -- @fields do
      [] -> :ok
      unknown -> {:error, "command_sandbox has unknown keys #{inspect(unknown)}; allowed: #{Enum.join(@fields, ", ")}"}
    end
  end

  defp validate_list(_field, nil), do: :ok

  defp validate_list(field, paths) when is_list(paths) do
    Enum.find_value(paths, :ok, fn path ->
      case validate_path(path) do
        :ok -> nil
        {:error, reason} -> {:error, "command_sandbox.#{field}: #{inspect(path)} #{reason}"}
      end
    end)
  end

  defp validate_list(field, _other), do: {:error, "command_sandbox.#{field} must be a list of absolute paths"}

  defp validate_path(path) when is_binary(path) do
    segments = Path.split(path)
    home = Path.expand(System.user_home!())
    aiur_home = Path.join(home, ".aiur")

    cond do
      Path.type(path) != :absolute -> {:error, "must be absolute"}
      ".." in segments -> {:error, "must not contain .."}
      Path.expand(path) == "/" -> {:error, "must not be /"}
      Path.expand(path) == home -> {:error, "must not be the operator home"}
      Path.expand(path) == aiur_home or String.starts_with?(Path.expand(path), aiur_home <> "/") -> {:error, "must not be under ~/.aiur"}
      true -> :ok
    end
  end

  defp validate_path(_other), do: {:error, "must be a string"}
end
