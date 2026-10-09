defmodule Aiur.GitHub.ChangedPaths do
  @moduledoc "Validates complete PR-file collections before deriving ownership."

  @spec decode([term()]) :: {:ok, [String.t()]} | {:error, :invalid_pr_files_response}
  def decode(files) do
    if Enum.all?(files, &valid_file?/1) do
      {:ok, Enum.map(files, & &1["filename"])}
    else
      {:error, :invalid_pr_files_response}
    end
  end

  defp valid_file?(%{"filename" => path}) when is_binary(path), do: String.trim(path) != ""
  defp valid_file?(_), do: false
end
