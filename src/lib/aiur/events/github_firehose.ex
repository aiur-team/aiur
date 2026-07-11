defmodule Aiur.Events.GithubFirehose do
  @moduledoc """
  Polls GitHub `/repos/{owner}/{repo}/events` and translates each
  relevant event into an `Aiur.Events.Publisher.publish/3` call.

  The orchestrator calls `poll/2` inside `:run_poll_cycle` with the
  cached ETag; this module returns the updated ETag for the next call.
  GitHub honors `If-None-Match`, so steady-state polling is cheap
  (304 No Content + rate-limit-free).

  ## What we publish

  The firehose is intentionally narrow. Ticket branch pushes come from
  `Aiur.Events.LsRemoteTicker`, and comments come from
  `Aiur.Events.GithubCommentsPoller`.

  | GitHub event type | Published topic                                   |
  |-------------------|---------------------------------------------------|
  | `PushEvent` (default branch)            | `system.<branch>.branch.push` |
  | `PullRequestEvent action=opened`        | `ticket.<id>.pr.opened`   |
  | `PullRequestEvent action=closed merged` | `ticket.<id>.pr.merged`   |

  Other event types are dropped silently. v1 keeps the surface narrow;
  add new types here as the brainstorm/use-cases call for them.

  ## What we DON'T do here

  - **Contamination filter** — Publisher handles it (`issue_number` opt
    is passed; tracked_fn drops the rest).
  - **CODEOWNERS filter** — applied at the sanitization layer
    downstream of Publisher (U15-U17, separate units).
  """

  require Logger

  alias Aiur.Events.{GithubKeys, Publisher, Sanitizer}
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
      {:ok, {:not_modified, etag, poll_interval}} ->
        {:ok, %{etag: etag, last_event_id: last_event_id, count: 0, poll_interval: poll_interval}}

      {:ok, {:events, events, etag, poll_interval}} ->
        with {:ok, pages} <- fetch_backfill_pages(events, last_event_id, opts) do
          events_to_publish = events_since_watermark(pages, last_event_id)

          count =
            events_to_publish
            |> Enum.map(&publish_one(&1, opts))
            |> Enum.count(&match?({:ok, _, _}, &1))

          {:ok,
           %{
             etag: etag,
             last_event_id: newest_event_id(events) || last_event_id,
             count: count,
             poll_interval: poll_interval
           }}
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

  defp publish_one(event, opts) do
    # The GitHub Events API surfaces the same historical events for
    # ~24h. On operator restart the dedup ETS table is empty, so
    # every PR-opened / push that happened before this boot would
    # fire as a fresh event and confuse blockee subscribers (e.g.
    # 101 reacts to a #100 push that already happened last run).
    # Drop anything older than the operator's boot wall-clock minus
    # a small jitter window. Real-time events created after boot
    # always pass through. Tests inject `boot_time:` directly.
    if GithubKeys.pre_boot_event?(event, opts) do
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
        sanitized = Sanitizer.github_payload(payload, Keyword.get(publish_opts, :actor))
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

    case GithubKeys.ref_to_topic(ref) do
      {:system, topic} ->
        payload = %{
          ref: ref,
          sha: sha,
          actor: actor,
          commits: get_in(event, ["payload", "commits"]) || [],
          repo: repo_name
        }

        {topic, payload, actor: actor}

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

    with {:ticket, id, _push_topic} <- GithubKeys.ref_to_topic("refs/heads/" <> head_ref),
         topic when is_binary(topic) <- pr_topic(id, action, Map.get(pr, "merged")) do
      publish_opts = [
        actor: actor,
        issue_number: id,
        bypass_contamination: action == "closed" and Map.get(pr, "merged") == true,
        dedup_key: GithubKeys.pr_dedup_key(repo_name, pr_number, action, head_sha)
      ]

      {topic, %{action: action, pr: pr}, publish_opts}
    else
      _ -> nil
    end
  end

  defp translate(_event, _opts), do: nil

  defp pr_topic(id, "opened", _merged), do: "ticket.#{id}.pr.opened"
  defp pr_topic(id, "closed", true), do: "ticket.#{id}.pr.merged"
  defp pr_topic(_id, _action, _merged), do: nil
end
