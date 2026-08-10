defmodule Aiur.Config.Error do
  @moduledoc false

  alias Aiur.Workflow

  @spec format(term()) :: String.t()
  def format(reason) do
    label = Path.basename(Workflow.workflow_file_path())
    format(reason, label)
  end

  defp format({:invalid_workflow_config, message}, label),
    do: "Invalid #{label} config: #{message}"

  defp format({:missing_workflow_file, path, raw_reason}, _label) do
    "Missing #{Path.basename(path)} at #{path}: #{inspect(raw_reason)}. " <>
      "Run `aiur init` to scaffold a .aiur/config."
  end

  defp format({:missing_workflow_file, %{cwd: cwd, searched_paths: searched_paths}}, _label) do
    "No Aiur config found. Resolved working directory: #{cwd}. " <>
      "Searched paths: #{Enum.join(searched_paths, ", ")}. " <>
      "Run `aiur init` to scaffold a .aiur/config."
  end

  defp format({:invalid_boot_configuration, path, raw_reason}, _label),
    do: "Invalid Aiur config at #{path}: #{format_boot_error(raw_reason)}"

  defp format({:restart_required_configuration_change, old_identity, new_identity}, _label) do
    "tracker repository/base changes require a daemon restart; " <>
      "running=#{inspect(old_identity)} requested=#{inspect(new_identity)}"
  end

  defp format(:missing_github_repo, _label),
    do: "GitHub tracker requires an explicit tracker.github.repo"

  defp format(:missing_base_branch, _label),
    do: "tracker.base_branch is required; Aiur will not guess a merge destination"

  defp format({tag, path, raw_reason}, _label)
       when tag in [:missing_prompt_file, :missing_hooks_file, :missing_prewarm_file],
       do: "Missing #{missing_file_label(tag)} at #{path}: #{inspect(raw_reason)}"

  defp format({:invalid_hooks_file, path, raw_reason}, _label),
    do: "Invalid hooks_file at #{path}: #{inspect(raw_reason)}"

  defp format({:workflow_parse_error, raw_reason}, label),
    do: "Failed to parse #{label}: #{inspect(raw_reason)}"

  defp format(:workflow_front_matter_not_a_map, label),
    do: "Failed to parse #{label}: top-level YAML must be a map"

  defp format(other, label), do: "Invalid #{label} config: #{inspect(other)}"

  defp missing_file_label(:missing_prompt_file), do: "prompt_file"
  defp missing_file_label(:missing_hooks_file), do: "hooks_file"
  defp missing_file_label(:missing_prewarm_file), do: "prewarm base_build_file"

  defp format_boot_error(:missing_github_repo),
    do: "GitHub tracker requires an explicit tracker.github.repo"

  defp format_boot_error(:missing_base_branch),
    do: "tracker.base_branch is required; Aiur will not guess a merge destination"

  defp format_boot_error(reason), do: inspect(reason)
end
