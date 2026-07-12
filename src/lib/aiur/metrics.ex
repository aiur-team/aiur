defmodule Aiur.Metrics do
  @moduledoc "Shared path convention for append-only runtime metric streams."

  @metrics_subdir "metrics"

  @doc "Resolves a configured metric path or a file beneath the active log root."
  @spec file(atom(), String.t()) :: Path.t()
  def file(override_key, filename) when is_atom(override_key) and is_binary(filename) do
    case Application.get_env(:aiur, override_key) do
      path when is_binary(path) -> path
      _other -> default_file(filename)
    end
  end

  defp default_file(filename) do
    log_file = Application.get_env(:aiur, :log_file, Aiur.LogFile.default_log_file())
    log_file |> Path.dirname() |> Path.join(@metrics_subdir) |> Path.join(filename)
  end
end
