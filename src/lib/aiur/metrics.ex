defmodule Aiur.Metrics do
  @moduledoc "Shared path convention for runtime metric files."

  alias Aiur.Config.Paths

  @metrics_subdir "metrics"

  @type scope :: :log_root | :decision_state

  @doc "Resolves a configured metric path beneath the selected runtime-state scope."
  @spec file(atom(), String.t(), scope()) :: Path.t()
  def file(override_key, filename, scope \\ :log_root)
      when is_atom(override_key) and is_binary(filename) and scope in [:log_root, :decision_state] do
    case Application.get_env(:aiur, override_key) do
      path when is_binary(path) -> path
      _other -> default_file(filename, scope)
    end
  end

  defp default_file(filename, scope) do
    scope
    |> base_directory()
    |> Path.join(@metrics_subdir)
    |> Path.join(filename)
  end

  defp base_directory(:log_root) do
    Application.get_env(:aiur, :log_file, Aiur.LogFile.default_log_file())
    |> Path.dirname()
  end

  defp base_directory(:decision_state) do
    case Paths.decision_state_dir() do
      {:ok, directory} -> directory
      {:error, _reason} -> base_directory(:log_root)
    end
  end
end
