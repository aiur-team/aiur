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

  The lists themselves are deposited beside the validators, so the store holds
  the full validator/body pair. That is what lets a `304` *answer* rather than
  only say "unchanged": the held list is run back through the same publish path,
  and the per-comment command dedup key suppresses everything already handled,
  so only a command the publish path itself dropped surfaces again — the same
  recovery the comment poller has. Before the bodies were deposited, a `304`
  against a stream had nothing to replay and anything the publish dropped was
  simply gone.
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

    {review_etag_in, review_provenance} = durable_etag(review_resource, Map.get(etags, :command_scan_review))
    {issue_etag_in, issue_provenance} = durable_etag(issue_resource, Map.get(etags, :command_scan_issue))

    {review_comments, review_etag, review_deposit?} =
      command_scan_review_comments(review_resource, review_provenance, Keyword.put(fetch_opts, :etag, review_etag_in))

    {issue_comments, issue_etag, issue_deposit?} =
      command_scan_issue_comments(issue_resource, issue_provenance, Keyword.put(fetch_opts, :etag, issue_etag_in))

    pr_comments =
      (review_comments ++ issue_comments)
      |> Enum.map(&command_scan_annotate(&1))
      |> Enum.reject(&is_nil(command_scan_comment_pr_number(&1)))

    # Advance the cursor over EVERY PR comment seen this cycle, not just the
    # command hits, so a non-command comment newer than a command doesn't make
    # the cursor stall and re-scan the command next cycle.
    newest = command_scan_newest_datetime(pr_comments)

    publish_command_hits(pr_comments, repo, command_scan_limit(opts))

    # Each stream's comment list is deposited as the entry's body beside its
    # validator — the store's validator/body contract — and only after the
    # publish above. The body is what makes a later `304` *answer*: it replays
    # the held list through the same publish path, and the per-comment command
    # dedup key suppresses everything already handled, so only a command the
    # publish path itself dropped (a Publisher refusal, a partial fan-out)
    # surfaces again. Deposited after the publish for the same reason the old
    # `put_etag/2` was: a cycle that read a command and died before publishing
    # it leaves no entry at all, so the next scan reads unconditionally and
    # finds it again.
    maybe_remember_list(review_deposit?, review_resource, review_comments, review_etag)
    maybe_remember_list(issue_deposit?, issue_resource, issue_comments, issue_etag)

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
  #
  # Answers `{comments, etag, deposit?}`: `deposit?` is false only for a `304`
  # against a validator the store cannot serve — nothing was deposited there,
  # so an empty list must not be written over it. See
  # `command_scan_unchanged_list/3`.
  defp command_scan_review_comments(resource, provenance, fetch_opts) do
    fetcher =
      Keyword.get_lazy(fetch_opts, :command_scan_review_comment_fetcher, fn ->
        fn scan_opts -> GitHubClient.fetch_recent_repo_review_comments_conditional(scan_opts) end
      end)

    case fetcher.(fetch_opts) do
      {:ok, comments, etag} when is_list(comments) ->
        {comments, etag, true}

      {:not_modified, etag} ->
        command_scan_unchanged_list(resource, provenance, etag)

      {:ok, comments} when is_list(comments) ->
        {comments, Keyword.get(fetch_opts, :etag), true}

      {:error, reason} ->
        Logger.warning("scan_pr_commands review-comment stream failed; reason=#{inspect(reason)}")
        {[], Keyword.get(fetch_opts, :etag), false}

      other ->
        Logger.warning("scan_pr_commands review-comment stream returned unexpected value: #{inspect(other)}")
        {[], Keyword.get(fetch_opts, :etag), false}
    end
  end

  # Fetch the repo-wide conversation-comment stream (issues/comments). The
  # endpoint returns comments on plain issues AND PR conversations; PR-number
  # derivation (command_scan_comment_pr_number/1) only resolves the PR ones,
  # so non-PR issue comments are dropped downstream (out of scope).
  defp command_scan_issue_comments(resource, provenance, fetch_opts) do
    fetcher =
      Keyword.get_lazy(fetch_opts, :command_scan_issue_comment_fetcher, fn ->
        fn scan_opts -> GitHubClient.fetch_recent_repo_issue_comments_conditional(scan_opts) end
      end)

    case fetcher.(fetch_opts) do
      {:ok, comments, etag} when is_list(comments) ->
        {comments, etag, true}

      {:not_modified, etag} ->
        command_scan_unchanged_list(resource, provenance, etag)

      {:ok, comments} when is_list(comments) ->
        {comments, Keyword.get(fetch_opts, :etag), true}

      {:error, reason} ->
        Logger.warning("scan_pr_commands issue-comment stream failed; reason=#{inspect(reason)}")
        {[], Keyword.get(fetch_opts, :etag), false}

      other ->
        Logger.warning("scan_pr_commands issue-comment stream returned unexpected value: #{inspect(other)}")
        {[], Keyword.get(fetch_opts, :etag), false}
    end
  end

  # The cycle's own map wins when it has an entry; the store answers only when it
  # does not, which after a restart is both streams.
  #
  # `etag/1` rather than `change_validator/1`, and the difference is the whole
  # point of holding a body: `etag/1` answers only when the store also holds the
  # list that validator describes, so a `304` against it can be served from that
  # held list instead of saying "unchanged" and handing the reader nothing. The
  # validator's provenance is returned with it because it decides what a `304`
  # against it is allowed to mean — see `command_scan_unchanged_list/3`.
  defp durable_etag(_resource, etag) when is_binary(etag) and etag != "", do: {etag, :cycle}
  defp durable_etag(resource, _etag), do: {ResourceStore.etag(resource), :store}

  # The stream's comment list and its validator, deposited together and only
  # after the commands in it were published — the poller's `remember_list/3`,
  # applied to the repo-wide streams. The body is what lets a later `304`
  # replay the list through the publish path (see
  # `command_scan_unchanged_list/3`). Re-depositing the same list on a `304`
  # refresh publishes nothing — the body and validator are unchanged — and only
  # keeps the entry alive inside the store's retention window.
  defp remember_list(resource, comments, etag) when is_list(comments) do
    ResourceStore.put_resource(resource, comments, etag: etag, source: :poll)
    etag
  end

  defp remember_list(_resource, _comments, etag), do: etag

  defp maybe_remember_list(true, resource, comments, etag), do: remember_list(resource, comments, etag)
  defp maybe_remember_list(false, _resource, _comments, _etag), do: :ok

  # What a `304` is worth, decided by what the store holds and where the
  # validator came from — mirrors `Aiur.Events.GithubCommentsPoller.unchanged_list/2`.
  #
  #   * the list itself — run it back through the publish path. Every comment
  #     in it is either already published, and suppressed by the command dedup
  #     key for free, or was never published, and is recovered. That is what
  #     makes a `304` produce the same events a `200` would have.
  #   * no list, but the validator is this daemon's own from an earlier cycle —
  #     nothing to recover: the `200` that minted it was published first (the
  #     store refused the body, or is not running). Keep the validator, because
  #     dropping it would make every steady-state cycle a full-price read,
  #     which is the cost this path exists to remove.
  #   * no list, and the validator came out of the store — it may have outlived
  #     the publish it was recorded beside, and it is an *endpoint* validator,
  #     so GitHub's `304` suppressed the whole list at once and nothing can see
  #     inside it. Unusable, so the validator is dropped and the next scan reads
  #     unconditionally.
  defp command_scan_unchanged_list(resource, provenance, etag) do
    case ResourceStore.fetch(resource) do
      {:ok, %{data: comments}} when is_list(comments) -> {comments, etag, true}
      _other when provenance == :cycle -> {[], etag, false}
      _other -> {[], drop_validator(resource), false}
    end
  end

  # A `304` against a durable validator with no body behind it spent a request
  # and learned nothing recoverable, so the validator goes and the next scan
  # reads unconditionally — the reader's half of the store's validator/body
  # contract; see `Aiur.GitHub.ResourceStore`.
  defp drop_validator(resource) do
    ResourceStore.drop_etag(resource)
    nil
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
      # The account a human @-mentions to command Aiur, and whose own comments
      # must not command it back — both are the login the daemon posts under,
      # which is the App bot when one is configured.
      Aiur.GitHub.Config.daemon_account()
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
