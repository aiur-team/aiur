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

  alias Aiur.Events.Publisher
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
        Publisher.publish(topic, payload, publish_opts)
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

        {topic, payload,
         actor: actor,
         issue_number: id,
         dedup_key: {repo_name, ref, sha}}

      {:system, topic} ->
        payload = %{
          ref: ref,
          sha: sha,
          actor: actor,
          commits: get_in(event, ["payload", "commits"]) || [],
          repo: repo_name
        }

        {topic, payload,
         actor: actor,
         dedup_key: {repo_name, ref, sha}}

      _ ->
        nil
    end
  end

  defp translate(%{"type" => "PullRequestEvent"} = event, _opts) do
    action = get_in(event, ["payload", "action"])
    pr = get_in(event, ["payload", "pull_request"]) || %{}
    ref = "refs/heads/" <> (Map.get(pr, "head", %{}) |> Map.get("ref", ""))
    actor = get_in(event, ["actor", "login"])

    case ref_to_topic(ref) do
      {:ticket, id, _push_topic} ->
        topic =
          cond do
            action == "opened" -> "ticket.#{id}.pr.opened"
            action == "closed" and Map.get(pr, "merged") == true -> "ticket.#{id}.pr.merged"
            true -> nil
          end

        if topic do
          {topic, %{action: action, pr: pr}, actor: actor, issue_number: id}
        end

      _ ->
        nil
    end
  end

  defp translate(%{"type" => "IssueCommentEvent"} = event, _opts) do
    issue = get_in(event, ["payload", "issue"]) || %{}
    number = Map.get(issue, "number")
    comment = get_in(event, ["payload", "comment"]) || %{}
    actor = get_in(event, ["actor", "login"])

    if is_integer(number) do
      topic = "ticket.#{number}.issue.commented"
      payload = %{issue_number: number, comment: comment}
      {topic, payload, actor: actor, issue_number: number}
    end
  end

  defp translate(%{"type" => "PullRequestReviewCommentEvent"} = event, _opts) do
    pr = get_in(event, ["payload", "pull_request"]) || %{}
    number = Map.get(pr, "number")
    comment = get_in(event, ["payload", "comment"]) || %{}
    actor = get_in(event, ["actor", "login"])

    if is_integer(number) do
      topic = "ticket.#{number}.pr.review_comment"
      payload = %{issue_number: number, comment: comment}
      {topic, payload, actor: actor, issue_number: number}
    end
  end

  defp translate(_event, _opts), do: nil

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
end
