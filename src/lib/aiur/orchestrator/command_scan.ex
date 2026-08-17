defmodule Aiur.Orchestrator.CommandScan do
  @moduledoc """
  Repo-wide one-off PR command scan (/aiur, @bot) with cursor-based deduplication.
  All functions execute inside the orchestrator GenServer process.

  ## The validators are the repository's, not this scan's

  Both streams this module reads — `pulls/comments` and `issues/comments` for the
  whole repository — are conditional requests, and their `ETag`s used to live in
  `state.github_comment_etags` under the call-site names `:command_scan_review`
  and `:command_scan_issue`. Two things followed from that key. Nothing else could
  use the validator this scan had already earned, and a restart threw it away, so
  the first scan of every boot re-read both streams in full.

  They are now recorded in `Aiur.GitHub.ResourceStore` against the repository's
  own identity, which is what a validator actually belongs to. The in-memory map
  still wins while it has an entry — it is the newest thing this daemon knows —
  and the store answers for the cycle after a restart, exactly as
  `Aiur.Events.GithubCommentsPoller` already does for per-issue streams.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Events.{GithubKeys, PrCommandScanner, Publisher, Sanitizer}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator.State

  @command_scan_pull_requests_per_poll 25

  # The stream's own endpoint path is its identity. Two shapes of the same
  # repository, so the type alone would not distinguish them.
  @review_comment_stream "pulls/comments"
  @issue_comment_stream "issues/comments"

  @spec scan_pr_commands(State.t(), keyword()) :: State.t()
  def scan_pr_commands(%State{} = state, opts \\ []) do
    if Config.tracker_kind() == "github" and Aiur.GitHub.Config.pr_watch_enabled?() do
      do_scan_pr_commands(state, opts)
    else
      state
    end
  end

  @doc false
  @spec advance_command_scan_since(String.t() | nil, DateTime.t() | nil) :: String.t() | nil
  def advance_command_scan_since(since, nil), do: since

  def advance_command_scan_since(_since, %DateTime{} = newest) do
    newest
    |> DateTime.add(-1, :second)
    |> DateTime.to_iso8601()
  end

  defp do_scan_pr_commands(%State{} = state, opts) do
    since = command_scan_since(state, opts)
    etags = state.github_comment_etags
    repo = command_scan_repo(opts)
    fetch_opts = Keyword.put(opts, :since, since)

    review_resource = ResourceStore.key_for_repo(:repo_review_comment_stream, repo, @review_comment_stream)
    issue_resource = ResourceStore.key_for_repo(:repo_issue_comment_stream, repo, @issue_comment_stream)

    review_etag_in = durable_etag(review_resource, Map.get(etags, :command_scan_review))
    issue_etag_in = durable_etag(issue_resource, Map.get(etags, :command_scan_issue))

    {review_comments, review_etag} = command_scan_review_comments(Keyword.put(fetch_opts, :etag, review_etag_in))
    {issue_comments, issue_etag} = command_scan_issue_comments(Keyword.put(fetch_opts, :etag, issue_etag_in))

    remember_etag(review_resource, review_etag)
    remember_etag(issue_resource, issue_etag)

    pr_comments =
      (review_comments ++ issue_comments)
      |> Enum.map(&command_scan_annotate(&1))
      |> Enum.reject(&is_nil(command_scan_comment_pr_number(&1)))

    # Advance the cursor over EVERY PR comment seen this cycle, not just the
    # command hits, so a non-command comment newer than a command doesn't make
    # the cursor stall and re-scan the command next cycle.
    newest = command_scan_newest_datetime(pr_comments)

    publish_command_hits(pr_comments, repo, command_scan_limit(opts))

    %{
      state
      | github_command_scan_since: advance_command_scan_since(since, newest),
        github_comment_etags:
          etags
          |> Map.put(:command_scan_review, review_etag)
          |> Map.put(:command_scan_issue, issue_etag)
    }
  end

  # Fetch the repo-wide review-comment stream (pulls/comments). A failure is
  # logged and yields [] so the scan never raises; the cursor is unaffected
  # because command_scan_newest_datetime/1 only advances on comments seen.
  defp command_scan_review_comments(fetch_opts) do
    fetcher =
      Keyword.get_lazy(fetch_opts, :command_scan_review_comment_fetcher, fn ->
        fn scan_opts -> GitHubClient.fetch_recent_repo_review_comments_conditional(scan_opts) end
      end)

    case fetcher.(fetch_opts) do
      {:ok, comments, etag} when is_list(comments) ->
        {comments, etag}

      {:not_modified, etag} ->
        {[], etag}

      {:ok, comments} when is_list(comments) ->
        {comments, Keyword.get(fetch_opts, :etag)}

      {:error, reason} ->
        Logger.warning("scan_pr_commands review-comment stream failed; reason=#{inspect(reason)}")
        {[], Keyword.get(fetch_opts, :etag)}

      other ->
        Logger.warning("scan_pr_commands review-comment stream returned unexpected value: #{inspect(other)}")
        {[], Keyword.get(fetch_opts, :etag)}
    end
  end

  # Fetch the repo-wide conversation-comment stream (issues/comments). The
  # endpoint returns comments on plain issues AND PR conversations; PR-number
  # derivation (command_scan_comment_pr_number/1) only resolves the PR ones,
  # so non-PR issue comments are dropped downstream (out of scope).
  defp command_scan_issue_comments(fetch_opts) do
    fetcher =
      Keyword.get_lazy(fetch_opts, :command_scan_issue_comment_fetcher, fn ->
        fn scan_opts -> GitHubClient.fetch_recent_repo_issue_comments_conditional(scan_opts) end
      end)

    case fetcher.(fetch_opts) do
      {:ok, comments, etag} when is_list(comments) ->
        {comments, etag}

      {:not_modified, etag} ->
        {[], etag}

      {:ok, comments} when is_list(comments) ->
        {comments, Keyword.get(fetch_opts, :etag)}

      {:error, reason} ->
        Logger.warning("scan_pr_commands issue-comment stream failed; reason=#{inspect(reason)}")
        {[], Keyword.get(fetch_opts, :etag)}

      other ->
        Logger.warning("scan_pr_commands issue-comment stream returned unexpected value: #{inspect(other)}")
        {[], Keyword.get(fetch_opts, :etag)}
    end
  end

  # The cycle's own map wins when it has an entry; the store answers only when it
  # does not, which after a restart is both streams. Mirrors
  # `Aiur.Events.GithubCommentsPoller.durable_etag/2` deliberately — one rule for
  # every conditional read, so a reader cannot be surprised by which pipe warmed
  # its validator.
  defp durable_etag(_resource, etag) when is_binary(etag) and etag != "", do: etag
  defp durable_etag(resource, _etag), do: ResourceStore.etag(resource)

  defp remember_etag(resource, etag) do
    ResourceStore.put_etag(resource, etag)
    etag
  end

  # Stamp event-time trust (author_trusted? from the canonical CODEOWNERS U
  # bot U trusted-accounts set) and pin the derived PR number so later steps
  # don't re-derive it. The body/author the scanner reads stay untouched.
  defp command_scan_annotate(comment) when is_map(comment) do
    comment
    |> Sanitizer.stamp_author_trust(actor: command_scan_comment_author(comment))
    |> Map.put(:pr_number, derive_command_scan_pr_number(comment))
  end

  # Group the trusted command comments by PR number, bound the scan to a capped
  # number of distinct commanded PRs per cycle (logging the drop), and publish
  # a reactivation event for each comment under a kept PR.
  defp publish_command_hits(comments, repo, limit) do
    comments
    |> PrCommandScanner.commands(
      Aiur.GitHub.Config.command_prefix(),
      Aiur.GitHub.Config.bot_account()
    )
    |> group_command_hits_by_pr()
    |> cap_command_pr_hits(limit)
    |> Enum.each(fn {pr_number, hits} ->
      Enum.each(hits, &publish_command_reactivation(pr_number, &1, repo))
    end)
  end

  defp group_command_hits_by_pr(hits) do
    Enum.group_by(hits, &command_scan_comment_pr_number/1)
  end

  # Cap distinct commanded PRs per cycle. The streams are small per cursor
  # window, but a burst could surface commands on many PRs at once; keep a
  # bounded number and log the drop rather than silently truncating. Sorted by
  # PR number so the cap is deterministic across cycles.
  defp cap_command_pr_hits(hits_by_pr, limit) do
    sorted = Enum.sort_by(hits_by_pr, fn {pr_number, _hits} -> pr_number end)
    kept = Enum.take(sorted, limit)
    dropped = map_size(hits_by_pr) - length(kept)

    if dropped > 0 do
      Logger.warning("scan_pr_commands capped: kept=#{length(kept)} dropped=#{dropped} limit=#{limit}")
    end

    kept
  end

  # Emit the SAME PR-number reactivation signal U2 uses
  # (ticket.<pr#>.pr.review_comment) with bypass_contamination: true so it
  # reaches the orchestrator even though the commanded PR is absent from the
  # tracked set (mirrors the firehose bypass_contamination path). The
  # Publisher's bot_self_loop? and dedup gates still apply.
  defp publish_command_reactivation(pr_number, comment, repo) do
    target = to_string(pr_number)
    actor = command_scan_comment_author(comment)

    payload =
      %{issue_number: target, comment: comment}
      |> Sanitizer.github_payload(actor)

    Publisher.publish(
      "ticket.#{target}.pr.review_comment",
      payload,
      issue_number: target,
      actor: actor,
      bypass_contamination: true,
      dedup_key:
        GithubKeys.comment_dedup_key(
          repo,
          "pr_command",
          pr_number,
          Map.get(comment, "id")
        )
    )
  end

  defp command_scan_comment_author(comment) when is_map(comment) do
    get_in(comment, ["user", "login"]) || get_in(comment, ["author", "login"])
  end

  # The derived PR number, read from the annotation pinned by
  # command_scan_annotate/1.
  defp command_scan_comment_pr_number(comment) when is_map(comment) do
    Map.get(comment, :pr_number)
  end

  # Derive the PR number from a stream comment. Review comments carry
  # pull_request_url (.../pulls/<n>); conversation comments carry
  # issue_url (.../issues/<n>) and are PRs only when html_url contains
  # /pull/ (a plain issue's html_url contains /issues/). Returns nil for
  # non-PR issue comments and any malformed URL, dropping them from the scan.
  defp derive_command_scan_pr_number(%{"pull_request_url" => url}) when is_binary(url) do
    parse_trailing_number(url)
  end

  defp derive_command_scan_pr_number(%{"issue_url" => url} = comment) when is_binary(url) do
    if command_scan_pr_html_url?(comment), do: parse_trailing_number(url)
  end

  defp derive_command_scan_pr_number(_comment), do: nil

  defp command_scan_pr_html_url?(%{"html_url" => html_url}) when is_binary(html_url) do
    String.contains?(html_url, "/pull/")
  end

  defp command_scan_pr_html_url?(_comment), do: false

  defp parse_trailing_number(url) when is_binary(url) do
    case url |> String.split("/") |> List.last() |> Integer.parse() do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp command_scan_repo(opts) do
    Keyword.get(opts, :repo) || Aiur.Tracker.project_identity()
  end

  defp command_scan_since(%State{github_command_scan_since: since}, _opts)
       when is_binary(since),
       do: since

  defp command_scan_since(%State{}, opts), do: GithubKeys.boot_cutoff_iso8601(opts)

  defp command_scan_limit(opts) do
    case Keyword.get(opts, :command_scan_pull_request_limit, @command_scan_pull_requests_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @command_scan_pull_requests_per_poll
    end
  end

  defp command_scan_newest_datetime(comments) do
    Enum.reduce(comments, nil, fn comment, newest ->
      max_command_scan_datetime(newest, command_scan_comment_datetime(comment))
    end)
  end

  defp command_scan_comment_datetime(comment) when is_map(comment) do
    comment
    |> Map.get("updated_at", Map.get(comment, "created_at"))
    |> parse_command_scan_datetime()
  end

  defp parse_command_scan_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_command_scan_datetime(_value), do: nil

  defp max_command_scan_datetime(nil, datetime), do: datetime
  defp max_command_scan_datetime(datetime, nil), do: datetime

  defp max_command_scan_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _ -> left
    end
  end
end
