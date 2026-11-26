defmodule Aiur.OverlapReviewer.Corpus do
  @moduledoc false

  alias Aiur.BuildOrder.Features
  alias Aiur.GitHub.{Access, Client, Config, OpenIssueSnapshot}
  alias Aiur.OverlapReviewer.Matcher
  alias Aiur.{RecentMerge, RecentMergeStore, TicketBranch}

  @snapshot_max_age_ms 10 * 60_000
  @merge_window_seconds 14 * 86_400

  @spec capture() :: {:ok, map()} | {:error, term()}
  def capture do
    with {:ok, pulls} <- Client.fetch_open_pull_request_listing_stored([], {:max_age_ms, 60_000}, "overlap_review"),
         {:ok, repo, issues, observed_at} <- issue_rows() do
      case cached_pulls(repo) do
        {:ok, held_pulls, pulled_at} -> {:ok, build_current(repo, issues, observed_at, held_pulls, pulled_at)}
        {:error, _reason} -> {:ok, build_current(repo, issues, observed_at, pulls, System.system_time(:millisecond))}
      end
    end
  end

  @spec cached(map() | nil) :: map() | nil
  def cached(previous) do
    with {:ok, repo, issues, observed_at} <- issue_rows(),
         {:ok, pulls, pulled_at} <- cached_pulls(repo) do
      case previous do
        %{repo: ^repo, observed_at: ^observed_at, pulled_at: ^pulled_at} -> previous
        _ -> build_current(repo, issues, observed_at, pulls, pulled_at)
      end
    else
      {:error, _reason} -> previous
    end
  end

  defp issue_rows do
    with repo when is_binary(repo) <- Config.repo(),
         [owner, name] <- String.split(repo, "/", parts: 2),
         {:ok, issues, observed_at} <- OpenIssueSnapshot.fetch_issue_rows(owner, name, @snapshot_max_age_ms) do
      {:ok, String.downcase(repo), issues, observed_at}
    else
      _ -> {:error, :open_issue_listing_unavailable}
    end
  end

  defp build_current(repo, issues, observed_at, pulls, pulled_at) do
    repo
    |> build(issues, pulls, RecentMergeStore.list(), DateTime.utc_now(), observed_at)
    |> Map.put(:pulled_at, pulled_at)
  end

  defp cached_pulls(repo) do
    now = System.system_time(:millisecond)
    key = Access.key_for_repo(:branch_pull_request_listing_all, repo, "open")

    case Access.fetch_resource(key) do
      {:ok, %{data: pulls, fetched_at_ms: at}} when is_list(pulls) and is_integer(at) and now - at <= @snapshot_max_age_ms -> {:ok, pulls, at}
      _ -> {:error, :open_pull_request_listing_unavailable}
    end
  end

  @spec build(String.t(), [map()], [map()], [RecentMerge.t()], DateTime.t(), integer()) :: map()
  def build(repo, issues, pulls, merges, now, observed_at) do
    open_issues = for issue <- issues, number = number(issue.identifier), into: %{}, do: {number, Matcher.document(:issue, number, issue.title, issue.description)}

    open_pulls =
      for %{"number" => number, "state" => "open"} = pull <- pulls, is_integer(number) and number > 0, into: %{} do
        {number, pull_document(pull, repo)}
      end

    cutoff = DateTime.add(now, -@merge_window_seconds)

    recent_merges =
      for merge <- merges, String.downcase(merge.repository) == String.downcase(repo), DateTime.compare(merge.merged_at, cutoff) != :lt do
        tickets = [merge.ticket_id | RecentMerge.closing_issue_identifiers(merge)]
        body = Enum.join([merge.summary | merge.commit_messages], "\n")
        Matcher.document(:merged_pr, merge.number, merge.title, body, numbers(tickets))
      end

    %{
      repo: String.downcase(repo),
      observed_at: observed_at,
      issues: open_issues,
      pulls: open_pulls,
      documents: Map.values(open_issues) ++ Map.values(open_pulls) ++ recent_merges
    }
  end

  @spec pull_document(map(), String.t()) :: map()
  def pull_document(%{"number" => number} = pull, repo) do
    body = pull["body"]
    head = get_in(pull, ["head", "ref"])
    head_repo = get_in(pull, ["head", "repo", "full_name"])

    ticket =
      if is_binary(head_repo) and String.downcase(head_repo) == String.downcase(repo), do: TicketBranch.ticket_id(head)

    tickets = [ticket | RecentMerge.closing_issue_identifiers_in_body(body, repo)]
    feature_tickets = tickets ++ RecentMerge.referenced_issue_identifiers_in_body(body, repo)

    :open_pr
    |> Matcher.document(number, pull["title"], body, numbers(tickets))
    |> Map.put(:head_sha, get_in(pull, ["head", "sha"]))
    |> Map.put(:feature_ticket_numbers, numbers(feature_tickets))
  end

  @spec memberships() :: {:ok, map()} | :unavailable
  def memberships do
    case Features.snapshot() do
      {:ok, %{owners: owners, also: also}} ->
        {:ok, Enum.reduce(owners, also, fn {number, %{feature: slug}}, acc -> Map.update(acc, number, [slug], &[slug | &1]) end)}

      _ ->
        :unavailable
    end
  end

  @spec current?(map(), integer()) :: boolean()
  def current?(%{observed_at: observed_at} = corpus, now_ms) do
    now_ms - min(observed_at, Map.get(corpus, :pulled_at, observed_at)) <= @snapshot_max_age_ms
  end

  @spec number(term()) :: pos_integer() | nil
  def number(value) when is_integer(value) and value > 0, do: value

  def number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  def number(_value), do: nil

  defp numbers(ids), do: ids |> Enum.map(&number/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
end
