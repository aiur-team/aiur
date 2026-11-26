defmodule Aiur.AgentEnvironment.TestRunIsolation do
  @moduledoc false

  @spec remote_github_budget_exports() :: String.t()
  def remote_github_budget_exports do
    case {System.get_env("AIUR_DEV_TEST_TICKET_IDS"), System.get_env("AIUR_DEV_TEST_RUN_ID")} do
      {scope, run_id} when is_binary(scope) and scope != "" ->
        run_id =
          if is_binary(run_id) and Regex.match?(~r/\Aaiur-test-budget\.[A-Za-z0-9_-]+\z/, run_id),
            do: run_id,
            else: "unbound-#{System.unique_integer([:positive])}"

        "export AIUR_GITHUB_BUDGET_ROOT=\"$HOME/.aiur/test-sandboxes/#{run_id}/github-budget\"\n" <>
          "export AIUR_GITHUB_CREDENTIAL_FILE=\"$AIUR_GITHUB_BUDGET_ROOT/agent-token\"\n"

      _ordinary_run ->
        "export AIUR_GITHUB_BUDGET_ROOT='~/.aiur/github-budget'\n" <>
          "AIUR_GITHUB_BUDGET_ROOT=\"$HOME/${AIUR_GITHUB_BUDGET_ROOT#\\~/}\"\nexport AIUR_GITHUB_BUDGET_ROOT\n" <>
          "export AIUR_GITHUB_CREDENTIAL_FILE='~/.aiur/github-budget/agent-token'\n" <>
          "AIUR_GITHUB_CREDENTIAL_FILE=\"$HOME/${AIUR_GITHUB_CREDENTIAL_FILE#\\~/}\"\nexport AIUR_GITHUB_CREDENTIAL_FILE\n"
    end
  end
end
