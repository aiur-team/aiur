defmodule Aiur.Config.Error do
  @moduledoc false

  alias Aiur.Workflow

  @spec format(term()) :: String.t()
  def format(reason) do
    label = Path.basename(Workflow.workflow_file_path())

    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid #{label} config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing #{Path.basename(path)} at #{path}: #{inspect(raw_reason)}. " <>
          "Run `aiur init` to scaffold a .aiur/config."

      {:missing_workflow_file, %{cwd: cwd, searched_paths: searched_paths}} ->
        "No Aiur config found. Resolved working directory: #{cwd}. " <>
          "Searched paths: #{Enum.join(searched_paths, ", ")}. " <>
          "Run `aiur init` to scaffold a .aiur/config."

      {:invalid_boot_configuration, path, raw_reason} ->
        "Invalid Aiur config at #{path}: #{format_boot_error(raw_reason)}"

      {:restart_required_configuration_change, old_identity, new_identity} ->
        "tracker repository/base changes require a daemon restart; " <>
          "running=#{inspect(old_identity)} requested=#{inspect(new_identity)}"

      :missing_github_repo ->
        "GitHub tracker requires an explicit tracker.github.repo"

      :missing_base_branch ->
        "tracker.base_branch is required; Aiur will not guess a merge destination"

      {tag, path, raw_reason}
      when tag in [:missing_prompt_file, :missing_hooks_file, :missing_prewarm_file] ->
        "Missing #{missing_file_label(tag)} at #{path}: #{inspect(raw_reason)}"

      {:invalid_hooks_file, path, raw_reason} ->
        "Invalid hooks_file at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse #{label}: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse #{label}: top-level YAML must be a map"

      other ->
        "Invalid #{label} config: #{inspect(other)}"
    end
  end

  defp missing_file_label(:missing_prompt_file), do: "prompt_file"
  defp missing_file_label(:missing_hooks_file), do: "hooks_file"
  defp missing_file_label(:missing_prewarm_file), do: "prewarm base_build_file"

  defp format_boot_error(:missing_github_repo),
    do: "GitHub tracker requires an explicit tracker.github.repo"

  defp format_boot_error(:missing_base_branch),
    do: "tracker.base_branch is required; Aiur will not guess a merge destination"

  defp format_boot_error(reason), do: inspect(reason)
end
