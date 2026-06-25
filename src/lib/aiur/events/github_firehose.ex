defmodule Aiur.Events.GithubFirehose do
  @moduledoc """
  Polls GitHub `/repos/{owner}/{repo}/events` and translates each
  relevant event into an `Aiur.Events.Publisher.publish/3` call.

  The orchestrator calls `poll/2` inside `:run_poll_cycle` with the
  cached ETag; this module returns the updated ETag for the next call.
  GitHub honors `If-None-Match`, so steady-state polling is cheap
  (304 No Content + rate-limit-free).

  ## What we publish

  v1 supports the events most useful for cross-ticket coordination:

  | GitHub event type | Published topic                                   |
  |-------------------|---------------------------------------------------|
  | `PushEvent` (ticket branch `aiur/<id>`) | `ticket.<id>.branch.push` |
  | `PushEvent` (default branch)            | `system.<branch>.branch.push` |
  | `PullRequestEvent action=opened`        | `ticket.<id>.pr.opened`   |
  | `PullRequestEvent action=closed merged` | `ticket.<id>.pr.merged`   |
  | `IssueCommentEvent`                     | `ticket.<id>.issue.commented` |
  | `PullRequestReviewCommentEvent`         | `ticket.<id>.pr.review_comment` |

  A PR-conversation comment arrives as an `IssueCommentEvent` keyed by
  the PR's number; `<id>` above is resolved back to the originating
  ticket via the PR's `aiur/<id>` head ref so the topic matches the
  agent's identifier (see `resolve_comment_ticket_id/3`).

  Other event types are dropped silently. v1 keeps the surface narrow;
  add new types here as the brainstorm/use-cases call for them.

  ## What we DON'T do here

  - **Contamination filter** — Publisher handles it (`issue_number` opt
    is passed; tracked_fn drops the rest).
  - **CODEOWNERS filter** — applied at the sanitization layer
    downstream of Publisher (U15-U17, separate units).
  - **`(repo, ref, sha)` dedup with ls-remote** — pass `dedup_key:` to
    Publisher so the firehose and ls-remote source dedupe each other.
  """

  require Logger

  alias Aiur.Events.{Publisher, Sanitizer}
  alias Aiur.GitHub.Client

  @repo_events_per_page 30
  @max_event_pages 5

  @doc """
  Polls one tick. Returns `{:ok, %{etag: ...}}` regardless of whether
  events fired — the etag is captured for the next call. On API failure
  (transport, 5xx, rate limit) returns `{:error, reason}`; the caller
  should preserve the previous etag.

  Options:
    * `:etag` — previously-captured ETag for `If-None-Match`
    * `:last_event_id` — newest GitHub event id observed on the previous poll
    * `:request_fun` — passed through to `Client.fetch_repo_events/1`
      (test injection)
    * `:repo` — `"owner/repo"` string used for `dedup_key`
  """
  @spec poll(keyword()) :: {:ok, map()} | {:error, term()}
  def poll(opts \\ []) do
    last_event_id = Keyword.get(opts, :last_event_id)

    client_opts =
      [etag: Keyword.get(opts, :etag), page: 1, per_page: @repo_events_per_page]
      |> maybe_put(:request_fun, Keyword.get(opts, :request_fun))

    case Client.fetch_repo_events(client_opts) do
      {:ok, {:not_modified, etag, _poll_interval}} ->
        {:ok, %{etag: etag, last_event_id: last_event_id, count: 0}}

      {:ok, {:events, events, etag, _poll_interval}} ->
        with {:ok, pages} <- fetch_backfill_pages(events, last_event_id, opts) do
          events_to_publish = events_since_watermark(pages, last_event_id)

          count =
            events_to_publish
            |> Enum.map(&publish_one(&1, opts))
            |> Enum.count(&match?({:ok, _, _}, &1))

          {:ok, %{etag: etag, last_event_id: newest_event_id(events) || last_event_id, count: count}}
        end

      {:error, reason} ->
        Logger.warning("GithubFirehose poll failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_backfill_pages(first_page, nil, _opts), do: {:ok, [first_page]}

  defp fetch_backfill_pages(first_page, last_event_id, opts) do
    if saturated_page?(first_page) and not event_id_present?(first_page, last_event_id) do
      fetch_backfill_pages([first_page], 2, last_event_id, opts)
    else
      {:ok, [first_page]}
    end
  end

  defp fetch_backfill_pages(pages, page, last_event_id, opts) when page <= @max_event_pages do
    client_opts =
      [page: page, per_page: @repo_events_per_page]
      |> maybe_put(:request_fun, Keyword.get(opts, :request_fun))

    case Client.fetch_repo_events(client_opts) do
      {:ok, {:events, events, _etag, _poll_interval}} ->
        pages = [events | pages]

        if saturated_page?(events) and not event_id_present?(events, last_event_id) do
          fetch_backfill_pages(pages, page + 1, last_event_id, opts)
        else
          {:ok, Enum.reverse(pages)}
        end

      {:ok, {:not_modified, _etag, _poll_interval}} ->
        {:ok, Enum.reverse(pages)}

      {:error, reason} ->
        Logger.warning("GithubFirehose backfill page=#{page} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_backfill_pages(pages, _page, _last_event_id, _opts), do: {:ok, Enum.reverse(pages)}

  defp saturated_page?(events), do: length(events) >= @repo_events_per_page

  defp event_id_present?(events, event_id) when is_binary(event_id) do
    Enum.any?(events, &(Map.get(&1, "id") == event_id))
  end

  defp event_id_present?(_events, _event_id), do: false

  defp events_since_watermark(pages, nil), do: List.first(pages) || []

  defp events_since_watermark(pages, last_event_id) do
    pages
    |> Enum.flat_map(& &1)
    |> Enum.take_while(&(Map.get(&1, "id") != last_event_id))
  end

  defp newest_event_id([%{"id" => id} | _]) when is_binary(id), do: id
  defp newest_event_id(_events), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Operator boot is captured once via `Aiur.Boot.epoch_seconds/0` (set
  # when the application starts). 60s back-window absorbs the gap
  # between a real push landing on GitHub and the firehose surfacing it
  # — without that buffer a push that arrived seconds before boot would
  # be dropped along with the truly stale ones.
  @pre_boot_buffer_seconds 60

  defp pre_boot?(event, opts) do
    case event_created_at_epoch(event) do
      nil ->
        false

      created_at ->
        cutoff = boot_epoch_seconds(opts) - @pre_boot_buffer_seconds
        created_at < cutoff
    end
  end

  defp event_created_at_epoch(event) do
    case Map.get(event, "created_at") do
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> DateTime.to_unix(dt)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp boot_epoch_seconds(opts) do
    case Keyword.get(opts, :boot_time) do
      ts when is_integer(ts) -> ts
      _ -> Aiur.Boot.epoch_seconds()
    end
  end

  defp publish_one(event, opts) do
    # The GitHub Events API surfaces the same historical events for
    # ~24h. On operator restart the dedup ETS table is empty, so
    # every PR-opened / push that happened before this boot would
    # fire as a fresh event and confuse blockee subscribers (e.g.
    # 101 reacts to a #100 push that already happened last run).
    # Drop anything older than the operator's boot wall-clock minus
    # a small jitter window. Real-time events created after boot
    # always pass through. Tests inject `boot_time:` directly.
    if pre_boot?(event, opts) do
      :pre_boot_drop
    else
      do_publish_one(event, opts)
    end
  end

  defp do_publish_one(event, opts) do
    case translate(event, opts) do
      nil ->
        :ignored

      {topic, payload, publish_opts} ->
        # Scrub user-content (truncate + redact + html-escape) and
        # stamp the CODEOWNERS trust flag + `source: :github` BEFORE
        # publish. Sanitization is universal for truncation/redaction;
        # the agent-digest renderer reads `author_trusted?` to decide
        # whether to surface the event to the agent prompt (operator-
        # visible surfaces always see it) and `source` to decide whether
        # to wrap user content in `<external-content>` at render.
        sanitized =
          payload
          |> Map.put(:source, :github)
          |> Sanitizer.scrub()
          |> Sanitizer.stamp_author_trust(actor: Keyword.get(publish_opts, :actor))
          |> Sanitizer.put_comment_message()

        Publisher.publish(topic, sanitized, publish_opts)
    end
  rescue
    error ->
      Logger.warning("GithubFirehose publish failed: #{Exception.message(error)}")
      :ignored
  end

  # ---------------------------------------------------------------------------
  # GitHub event → topic translation
  # ---------------------------------------------------------------------------

  defp translate(%{"type" => "PushEvent"} = event, opts) do
    ref = get_in(event, ["payload", "ref"])
    sha = get_in(event, ["payload", "head"])
    actor = get_in(event, ["actor", "login"])
    repo_name = get_in(event, ["repo", "name"]) || Keyword.get(opts, :repo)

    case ref_to_topic(ref) do
      {:ticket, id, topic} ->
        payload = %{
          ref: ref,
          sha: sha,
          actor: actor,
          commits: get_in(event, ["payload", "commits"]) || [],
          repo: repo_name
        }

        {topic, payload, actor: actor, issue_number: id, dedup_key: {repo_name, ref, sha}}

      {:system, topic} ->
        payload = %{
          ref: ref,
          sha: sha,
          actor: actor,
          commits: get_in(event, ["payload", "commits"]) || [],
          repo: repo_name
        }

        {topic, payload, actor: actor, dedup_key: {repo_name, ref, sha}}

      _ ->
        nil
    end
  end

  defp translate(%{"type" => "PullRequestEvent"} = event, opts) do
    action = get_in(event, ["payload", "action"])
    pr = get_in(event, ["payload", "pull_request"]) || %{}
    head_ref = get_in(pr, ["head", "ref"]) || ""
    head_sha = get_in(pr, ["head", "sha"]) || ""
    actor = get_in(event, ["actor", "login"])
    repo_name = get_in(event, ["repo", "name"]) || Keyword.get(opts, :repo)
    pr_number = Map.get(pr, "number")

    with {:ticket, id, _push_topic} <- ref_to_topic("refs/heads/" <> head_ref),
         topic when is_binary(topic) <- pr_topic(id, action, Map.get(pr, "merged")) do
      publish_opts = [
        actor: actor,
        issue_number: id,
        bypass_contamination: action == "closed" and Map.get(pr, "merged") == true,
        dedup_key: pr_dedup_key(repo_name, pr_number, action, head_sha)
      ]

      {topic, %{action: action, pr: pr}, publish_opts}
    else
      _ -> nil
    end
  end

  defp translate(%{"type" => "IssueCommentEvent"} = event, opts) do
    issue = get_in(event, ["payload", "issue"]) || %{}
    number = Map.get(issue, "number")
    comment = get_in(event, ["payload", "comment"]) || %{}
    actor = get_in(event, ["actor", "login"])
    repo_name = get_in(event, ["repo", "name"]) || Keyword.get(opts, :repo)
    comment_id = Map.get(comment, "id")
    dedup_key = comment_dedup_key(repo_name, "issue_comment", number, comment_id)

    cond do
      not is_integer(number) ->
        nil

      # The GitHub Events API replays in-window events for ~24h and the
      # Publisher dedups by `dedup_key` at publish time. Resolving a
      # PR-conversation comment to its ticket id costs a synchronous
      # head-ref GET (the IssueCommentEvent's `issue.pull_request` carries
      # no head ref), so short-circuit on a dedup hit BEFORE that lookup —
      # otherwise the same in-window comment re-fetches the head ref on
      # every poll cycle until it ages out of the dedup window. (#408)
      already_deduped?(dedup_key) ->
        nil

      true ->
        # A PR-conversation comment fires as an IssueCommentEvent whose
        # `issue.number` is the PR's number, not the originating ticket's.
        # Resolve it to the ticket id via the PR's `aiur/<id>` head ref so
        # the topic matches the agent's identifier — the orchestrator
        # reactivates a `:deactivated` entry and live agents subscribe by
        # ticket id. Mirrors how PullRequestEvent already keys by head ref.
        # Plain issue comments carry no `pull_request` key and already use
        # the ticket number.
        ticket_id = resolve_comment_ticket_id(issue, number, opts)

        # `bypass_contamination`: a `:deactivated` ticket (agent in
        # human-review) is intentionally excluded from the orchestrator's
        # tracked set so the killed task's late `agent.*` events stay
        # filtered. An inbound human comment, however, must still reach the
        # orchestrator to reactivate that entry — so it skips the tracked
        # filter. The orchestrator (and live agents) self-gate by
        # subscription, so a comment on an untracked issue reaches no
        # reactivation target.
        publish_opts = [
          actor: actor,
          issue_number: ticket_id,
          bypass_contamination: true,
          dedup_key: dedup_key
        ]

        {"ticket.#{ticket_id}.issue.commented", %{issue_number: ticket_id, comment: comment}, publish_opts}
    end
  end

  defp translate(%{"type" => "PullRequestReviewCommentEvent"} = event, opts) do
    pr = get_in(event, ["payload", "pull_request"]) || %{}
    number = Map.get(pr, "number")
    comment = get_in(event, ["payload", "comment"]) || %{}
    actor = get_in(event, ["actor", "login"])
    repo_name = get_in(event, ["repo", "name"]) || Keyword.get(opts, :repo)
    comment_id = Map.get(comment, "id")

    if is_integer(number) do
      ticket_id = resolve_pr_ticket_id(pr, number, opts)

      publish_opts = [
        actor: actor,
        issue_number: ticket_id,
        bypass_contamination: true,
        dedup_key: comment_dedup_key(repo_name, "pr_review_comment", number, comment_id)
      ]

      {"ticket.#{ticket_id}.pr.review_comment", %{issue_number: ticket_id, comment: comment}, publish_opts}
    end
  end

  defp translate(_event, _opts), do: nil

  # Pre-check the Publisher dedup table with the same key `publish/3`
  # would record. Lets the firehose skip a comment's ticket-id resolution
  # (a synchronous head-ref GET for PR-conversation comments) when the
  # event is a GitHub Events-API replay already published this window.
  # `push_seen?/3` is a read-only lookup; the recording side-effect stays
  # in `Publisher.publish/3`, so the first sighting still publishes.
  defp already_deduped?({repo, ref, sha})
       when is_binary(repo) and is_binary(ref) and is_binary(sha),
       do: Publisher.push_seen?(repo, ref, sha)

  defp already_deduped?(_), do: false

  # Resolve a comment's topic ticket id. For a PR-conversation comment
  # (`issue.pull_request` present) look up the PR's `aiur/<id>` head ref
  # and return `<id>`. On any failure — lookup error, or a non-`aiur/`
  # branch — fall back to the raw number so the event still publishes
  # rather than being dropped (matches pre-resolution behavior). A plain
  # issue comment's number already IS the ticket id.
  defp resolve_comment_ticket_id(issue, number, opts) do
    if is_map(Map.get(issue, "pull_request")) do
      resolve_pr_ticket_id(%{}, number, opts)
    else
      number
    end
  end

  defp resolve_pr_ticket_id(pr, number, opts) do
    with head_ref when is_binary(head_ref) and head_ref != "" <- get_in(pr, ["head", "ref"]),
         {:ticket, id, _topic} <- ref_to_topic("refs/heads/" <> head_ref) do
      id
    else
      _ ->
        lookup = Keyword.get(opts, :pr_lookup_fun, &Client.fetch_pull_request_head_ref/1)

        with {:ok, head_ref} when is_binary(head_ref) <- lookup.(number),
             {:ticket, id, _topic} <- ref_to_topic("refs/heads/" <> head_ref) do
          id
        else
          _ -> number
        end
    end
  end

  defp pr_topic(id, "opened", _merged), do: "ticket.#{id}.pr.opened"
  defp pr_topic(id, "closed", true), do: "ticket.#{id}.pr.merged"
  defp pr_topic(_id, _action, _merged), do: nil

  # Match exactly `refs/heads/aiur/<id>` where `<id>` is digits only.
  # Mirrors `Aiur.Events.LsRemoteTicker.ref_to_topic/1` so both
  # detectors classify identical refs identically. A wider pattern
  # accepting `aiur/<id>-<slug>` would route unrelated dev branches
  # (e.g. `aiur/99-test-fixture`) to ticket 99's auto-resume hook —
  # the shared agent prompt locks branch naming to the canonical form.
  defp ref_to_topic(ref) when is_binary(ref) do
    case Regex.run(~r{\Arefs/heads/aiur/(\d+)\z}, ref) do
      [_, id] ->
        {:ticket, id, "ticket.#{id}.branch.push"}

      _ ->
        case Regex.run(~r{\Arefs/heads/([^/]+)\z}, ref) do
          [_, branch] -> {:system, "system.#{branch}.branch.push"}
          _ -> nil
        end
    end
  end

  defp ref_to_topic(_), do: nil

  # Dedup keys reuse Publisher's {binary, binary, binary} triple shape.
  # GitHub Events API returns the same historical event on every poll
  # within its ~24h window. Without these keys, opening a PR shows
  # `📤 opened a PR` once per poll cycle.
  defp pr_dedup_key(repo, pr_number, action, head_sha)
       when is_binary(repo) and is_integer(pr_number) and is_binary(action) and is_binary(head_sha),
       do: {repo, "pr:#{action}:#{pr_number}", head_sha}

  defp pr_dedup_key(_, _, _, _), do: nil

  defp comment_dedup_key(repo, kind, parent_number, comment_id)
       when is_binary(repo) and is_binary(kind) and is_integer(parent_number) and
              is_integer(comment_id),
       do: {repo, "#{kind}:#{parent_number}", Integer.to_string(comment_id)}

  defp comment_dedup_key(_, _, _, _), do: nil
end
