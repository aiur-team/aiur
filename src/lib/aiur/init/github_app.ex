defmodule Aiur.Init.GitHubApp do
  @moduledoc "GitHub App opt-in prompt for fresh `aiur init` setup."

  @github_token_choice "No — use my GITHUB_TOKEN"
  @github_app_choice "Yes — I'll set up a GitHub App"
  @prompt "Use a GitHub App for the daemon? (recommended if agents are hitting rate limits)"
  @setup_doc_prefix "https://github.com/aiur-team/aiur/blob"
  @container_mode_envs ["AIUR_SECRETS_FROM_ENV", "AIUR_STATE_PERSISTENT"]
  @github_events "issues, issue_comment, pull_request, pull_request_review, pull_request_review_comment, pull_request_review_thread, check_run, check_suite, push, branch_protection_rule, repository_ruleset, repository"

  @doc "Asks which daemon credential path a fresh GitHub setup will use."
  @spec prompt(Aiur.Init.io(), map()) :: :github_token | :github_app
  def prompt(io, %{kind: "github"} = tracker) do
    if container_setup?() do
      print_container_requirements(io, tracker)

      if Aiur.Secrets.truthy?(System.get_env("AIUR_GITHUB_ALLOW_PAT")) do
        :github_token
      else
        :github_app
      end
    else
      prompt_local(io, tracker)
    end
  end

  def prompt(_io, _tracker), do: :github_token

  defp prompt_local(io, tracker) do
    io.puts.(
      "\nOptional GitHub App upgrade:\n" <>
        "  • Higher rate limits for busy fleets.\n" <>
        "  • Tighter daemon permissions than a classic PAT."
    )

    case io.select.(@prompt, [@github_token_choice, @github_app_choice], @github_token_choice) do
      @github_app_choice ->
        io.puts.("GitHub App setup steps: #{setup_doc(tracker)}")
        :github_app

      _choice ->
        :github_token
    end
  end

  defp container_setup? do
    Enum.any?(@container_mode_envs, &Aiur.Secrets.truthy?(System.get_env(&1)))
  end

  defp print_container_requirements(io, tracker) do
    io.puts.(
      "\nHosted/container GitHub setup (see #{github_auth_doc(tracker)}):\n" <>
        "  Use a GitHub App with these repository permissions: Contents Read and write; Issues Read and write; Pull requests Read and write; Checks Read; Actions Read (plus write for canary and automatic failed-job reruns). Metadata Read-only is implicit.\n" <>
        "  Subscribe the App to webhook events: #{@github_events}.\n" <>
        "  Set GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and GITHUB_APP_PRIVATE_KEY (or GITHUB_APP_PRIVATE_KEY_PATH)."
    )
  end

  defp setup_doc(tracker) do
    "#{@setup_doc_prefix}/#{Aiur.Config.base_branch(tracker)}/docs/security/daemon-token-posture.md"
  end

  defp github_auth_doc(tracker) do
    "#{@setup_doc_prefix}/#{Aiur.Config.base_branch(tracker)}/website/docs-app/apis/github-auth.md"
  end
end
