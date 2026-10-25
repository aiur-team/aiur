defmodule Aiur.GitHub.ChangedPaths do
  @moduledoc "Validates complete PR-file collections before deriving ownership."

  # GitHub's PR-files endpoint stops at 3000 files without a further `next`
  # link, so a collection that reaches the cap may be truncated: it is unknown.
  @github_files_cap 3000

  @spec decode([term()]) :: {:ok, [String.t()]} | {:error, :invalid_pr_files_response | :pr_files_truncated}
  def decode(files) do
    cond do
      length(files) >= @github_files_cap -> {:error, :pr_files_truncated}
      Enum.all?(files, &valid_file?/1) -> {:ok, Enum.map(files, & &1["filename"])}
      true -> {:error, :invalid_pr_files_response}
    end
  end

  defp valid_file?(%{"filename" => path}) when is_binary(path), do: String.trim(path) != ""
  defp valid_file?(_), do: false
end
