defmodule Aiur.RunTelemetry.GitHubFacts do
  @moduledoc "One governed terminal-ticket read; only derived PR scalars leave this module."

  alias Aiur.Events.BranchRefStore
  alias Aiur.GitHub.{CodeOwners, Transport}
  alias Aiur.TicketBranch

  @query """
  query AnalyticsFacts($owner: String!, $name: String!, $number: Int!, $branch: String!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {
        id number parent { number }
        timelineItems(first: 100, itemTypes: [CROSS_REFERENCED_EVENT]) {
          pageInfo { hasNextPage }
          nodes { ... on CrossReferencedEvent { source { ... on PullRequest { ...FactsPR } } } }
        }
      }
      pullRequests(first: 100, headRefName: $branch, orderBy: {field: CREATED_AT, direction: DESC}) {
        pageInfo { hasNextPage } nodes { ...FactsPR }
      }
    }
  }
  fragment FactsPR on PullRequest {
    number headRefName createdAt mergedAt isDraft additions deletions changedFiles
    commits(first: 1) { totalCount } mergeCommit { oid }
    closingIssuesReferences(first: 100) { pageInfo { hasNextPage } nodes { id number } }
    timelineItems(first: 100, itemTypes: [READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT]) {
      pageInfo { hasNextPage }
      nodes { __typename ... on ReadyForReviewEvent { createdAt } ... on ConvertToDraftEvent { createdAt } }
    }
    reviews(first: 100) {
      pageInfo { hasNextPage }
      nodes { state submittedAt author { __typename login } }
    }
  }
  """

  @spec fetch(map() | String.t() | pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(ticket, opts \\ []) do
    with {:ok, {owner, repo}} <- repository(opts),
         {:ok, number} <- ticket_number(ticket),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, response} <- request(token, owner, repo, number, ticket, opts) do
      normalize(response, opts)
    end
  end

  @spec normalize(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(response, opts \\ [])

  def normalize(%{"errors" => [_ | _]}, _opts), do: {:error, :graphql_partial}

  def normalize(%{"data" => %{"repository" => %{"issue" => %{} = issue} = repo}}, opts) do
    with {:ok, pulls} <- nodes(repo["pullRequests"]),
         {:ok, references} <- nodes(issue["timelineItems"]),
         {:ok, linked} <- linked_pulls(references, issue),
         {:ok, facts} <- pr_facts(select_pr(pulls, linked), opts) do
      {:ok, Map.merge(facts, %{epic: get_in(issue, ["parent", "number"]), coverage: "available"})}
    end
  end

  def normalize(_response, _opts), do: {:error, :invalid_github_facts}

  defp repository(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) ->
        case String.split(repo, "/") do
          [owner, name] when owner != "" and name != "" -> {:ok, {owner, name}}
          _ -> {:error, :invalid_github_repo}
        end

      _ ->
        Transport.parse_repo()
    end
  end

  defp ticket_number(ticket) when is_map(ticket), do: ticket_number(ticket[:identifier] || ticket[:ticket] || ticket[:id])
  defp ticket_number(ticket) when is_integer(ticket) and ticket > 0, do: {:ok, ticket}

  defp ticket_number(ticket) when is_binary(ticket) do
    case Integer.parse(ticket) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_ticket}
    end
  end

  defp ticket_number(_ticket), do: {:error, :invalid_ticket}

  defp request(token, owner, repo, number, ticket, opts) do
    branch = if is_map(ticket), do: ticket[:pr_head_ref] || ticket[:branch_name] || TicketBranch.branch_name(number, ticket[:title]), else: known_branch(number, opts)
    variables = %{"owner" => owner, "name" => repo, "number" => number, "branch" => branch}
    Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, @query, variables, caller: "analytics_facts")
  end

  defp known_branch(number, opts) do
    lookup = Keyword.get(opts, :branch_lookup, &BranchRefStore.latest/1)

    case lookup.(number) do
      %{ref: "refs/heads/" <> branch} -> branch
      _ -> TicketBranch.legacy_branch_name(number)
    end
  catch
    :exit, _ -> TicketBranch.legacy_branch_name(number)
  end

  # The one-query contract cannot page overflow: fail instead of inventing complete counts.
  defp nodes(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}) when is_list(nodes), do: {:ok, Enum.filter(nodes, &is_map/1)}
  defp nodes(%{"pageInfo" => %{"hasNextPage" => true}}), do: {:error, :incomplete_github_facts}
  defp nodes(_connection), do: {:error, :invalid_github_facts}

  defp linked_pulls(references, issue) do
    references
    |> Enum.map(& &1["source"])
    |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, "closingIssuesReferences")))
    |> Enum.reduce_while({:ok, []}, fn pr, {:ok, acc} ->
      case nodes(pr["closingIssuesReferences"]) do
        {:ok, issues} -> {:cont, {:ok, if(Enum.any?(issues, &(is_binary(issue["id"]) and &1["id"] == issue["id"])), do: [pr | acc], else: acc)}}
        error -> {:halt, error}
      end
    end)
  end

  defp select_pr(pulls, linked) do
    candidates = if pulls == [], do: linked, else: pulls
    Enum.max_by(candidates, &{not is_nil(&1["mergedAt"]), &1["createdAt"]}, fn -> nil end)
  end

  defp pr_facts(nil, _opts), do: {:ok, %{pr_number: nil}}

  defp pr_facts(pr, opts) do
    with {:ok, timeline} <- nodes(pr["timelineItems"]),
         {:ok, reviews} <- nodes(pr["reviews"]) do
      submitted = reviews |> Enum.filter(&(is_binary(&1["submittedAt"]) and &1["state"] != "PENDING")) |> Enum.sort_by(& &1["submittedAt"])
      first = List.first(submitted) || %{}
      approval = Enum.find(submitted, &(&1["state"] == "APPROVED")) || %{}

      {:ok,
       %{
         pr_number: pr["number"],
         pr_created_at: pr["createdAt"],
         pr_ready_at: ready_at(pr, timeline),
         first_review_at: first["submittedAt"],
         first_review_state: first["state"],
         first_approval_at: approval["submittedAt"],
         merged_at: pr["mergedAt"],
         review_count: length(submitted),
         changes_requested_count: Enum.count(submitted, &(&1["state"] == "CHANGES_REQUESTED")),
         approval_count: Enum.count(submitted, &(&1["state"] == "APPROVED")),
         commented_count: Enum.count(submitted, &(&1["state"] == "COMMENTED")),
         dismissed_count: Enum.count(submitted, &(&1["state"] == "DISMISSED")),
         reviewers_distinct: submitted |> Enum.map(&get_in(&1, ["author", "login"])) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(&String.downcase/1) |> length(),
         reviewer_classes: submitted |> Enum.map(&reviewer_class(&1["author"], opts)) |> Enum.uniq() |> Enum.sort(),
         additions: pr["additions"],
         deletions: pr["deletions"],
         changed_files: pr["changedFiles"],
         commit_count: get_in(pr, ["commits", "totalCount"]),
         merge_commit_sha: get_in(pr, ["mergeCommit", "oid"])
       }}
    end
  end

  defp ready_at(pr, timeline) do
    case Enum.sort_by(timeline, & &1["createdAt"]) |> List.first() do
      %{"__typename" => "ReadyForReviewEvent", "createdAt" => ready} -> ready
      %{"__typename" => "ConvertToDraftEvent"} -> pr["createdAt"]
      nil -> if pr["isDraft"], do: nil, else: pr["createdAt"]
    end
  end

  defp reviewer_class(%{"__typename" => "Bot"}, _opts), do: "bot"

  defp reviewer_class(%{"login" => login}, opts) when is_binary(login) do
    allowed = Keyword.get(opts, :allowed_fun, &trusted?/1)
    if allowed.(login), do: "trusted", else: "other"
  end

  defp reviewer_class(_author, _opts), do: "other"

  defp trusted?(login) do
    CodeOwners.allowed?(login)
  catch
    :exit, _reason -> false
  end
end
