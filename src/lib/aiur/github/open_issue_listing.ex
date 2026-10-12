defmodule Aiur.GitHub.OpenIssueListing do
  @moduledoc "Records and publishes complete open listings with their pre-request observation time."
  alias Aiur.AllowedContributors
  alias Aiur.GitHub.OpenIssueSnapshot

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(repository), do: Phoenix.PubSub.subscribe(Aiur.PubSub, topic(repository))

  @spec record(String.t(), String.t(), [Aiur.Issue.t()], DateTime.t()) :: :ok
  def record(owner, repo, issues, listed_from) do
    labels = Map.new(issues, &{&1.id, %{labels: &1.labels, updated_at: &1.updated_at}})
    OpenIssueSnapshot.put(owner, repo, Enum.map(issues, & &1.id), labels)
    AllowedContributors.offer_open_issues(issues)
    repository = String.downcase(owner <> "/" <> repo)

    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic(repository), {:open_issue_listing, repository, issues, listed_from})
    end

    :ok
  end

  defp topic(repository), do: "github:open_issue_listing:" <> String.downcase(repository)
end
