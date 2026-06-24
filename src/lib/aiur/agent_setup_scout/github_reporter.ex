defmodule Aiur.AgentSetupScout.GitHubReporter do
  @moduledoc """
  GitHub issue reporter for setup-friction scout findings.
  """

  @behaviour Aiur.AgentSetupScout.Reporter

  require Logger

  @impl true
  def report(%{title: title, body: body, labels: labels})
      when is_binary(title) and is_binary(body) and is_list(labels) do
    case client().create_issue(title, body, labels) do
      {:ok, _issue} ->
        :ok

      {:error, reason} ->
        Logger.warning("agent_setup_scout report skipped reason=#{inspect(reason)} title=#{inspect(title)}")
        {:error, reason}
    end
  end

  defp client do
    Application.get_env(:aiur, :agent_setup_scout_github_client, Aiur.GitHub.Client)
  end
end
