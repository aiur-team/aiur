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

  @doc """
  Polls one tick. Returns `{:ok, %{etag: ...}}` regardless of whether
  events fired — the etag is captured for the next call. On API failure
  (transport, 5xx, rate limit) returns `{:error, reason}`; the caller
  should preserve the previous etag.

  Options:
    * `:etag` — previously-captured ETag for `If-None-Match`
    * `:request_fun` — passed through to `Client.fetch_repo_events/1`
      (test injection)
    * `:repo` — `"owner/repo"` string used for `dedup_key`
  """
  @spec poll(keyword()) :: {:ok, map()} | {:error, term()}
  def poll(opts \\ []) do
    client_opts =
      [etag: Keyword.get(opts, :etag)]
      |> maybe_put(:request_fun, Keyword.get(opts, :request_fun))

    case Client.fetch_repo_events(client_opts) do
      {:ok, {:not_modified, etag, _poll_interval}} ->
        {:ok, %{etag: etag, count: 0}}

      {:ok, {:events, events, etag, _poll_interval}} ->
        count =
          events
          |> Enum.map(&publish_one(&1, opts))
          |> Enum.count(&match?({:ok, _, _}, &1))

        {:ok, %{etag: etag, count: count}}

      {:error, reason} ->
        Logger.warning("GithubFirehose poll failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp publish_one(event, opts) do
    case translate(event, opts) do
      nil ->
        :ignored

      {topic, payload, publish_opts} ->
        # Plan U7: scrub user-content (truncate + redact) and stamp the
        # CODEOWNERS trust flag BEFORE publish. Sanitization is universal
        # for truncation/redaction; the agent-digest renderer reads
        # `author_trusted?` to decide whether to surface the event to
        # the agent prompt (operator-visible surfaces always see it).
        sanitized =
          payload
          |> Sanitizer.scrub()
          |> Sanitizer.stamp_author_trust(actor: Keyword.get(publish_opts, :actor))

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

    if is_integer(number) do
      publish_opts = [
        actor: actor,
        issue_number: number,
        dedup_key: comment_dedup_key(repo_name, "issue_comment", number, comment_id)
      ]

      {"ticket.#{number}.issue.commented", %{issue_number: number, comment: comment}, publish_opts}
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
      publish_opts = [
        actor: actor,
        issue_number: number,
        dedup_key: comment_dedup_key(repo_name, "pr_review_comment", number, comment_id)
      ]

      {"ticket.#{number}.pr.review_comment", %{issue_number: number, comment: comment}, publish_opts}
    end
  end

  defp translate(_event, _opts), do: nil

  defp pr_topic(id, "opened", _merged), do: "ticket.#{id}.pr.opened"
  defp pr_topic(id, "closed", true), do: "ticket.#{id}.pr.merged"
  defp pr_topic(_id, _action, _merged), do: nil

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
