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

  alias Aiur.{Boot, RecentMerge, RecentMergeStore}
  alias Aiur.Events.{GithubKeys, Publisher, Sanitizer}
  alias Aiur.GitHub.Client

  @repo_events_per_page 30
  @max_event_pages 5

  @doc """
  Polls one tick. Returns `{:ok, %{etag: ...}}` regardless of whether
  events fired — the etag is captured for the next call. On API failure
  (transport, 5xx, rate limit) returns `{:error, reason}`; the caller
  should preserve the previous etag. A local recent-merge persistence failure
  returns its reason plus the successful response cursor so the caller can
  bound retries without refetching the same published event forever.

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
        {:ok,
         %{
           etag: etag,
           last_event_id: last_event_id,
           count: 0,
           poll_interval: poll_interval,
           recent_merge_persistence: :not_attempted
         }}

      {:ok, {:events, events, etag, poll_interval}} ->
        process_event_response(events, etag, poll_interval, last_event_id, opts)

      {:error, reason} ->
        Logger.warning("GithubFirehose poll failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_event_response(events, etag, poll_interval, last_event_id, opts) do
    with {:ok, %{pages: pages, partial?: partial?}} <-
           fetch_backfill_pages(events, last_event_id, opts) do
      processed = pages |> events_since_watermark(last_event_id) |> process_events(opts)
      pages_fetched = length(pages)

      result = %{
        etag: etag,
        last_event_id: newest_event_id(events) || last_event_id,
        count: processed.count,
        poll_interval: poll_interval,
        pages_fetched: pages_fetched,
        partial_window?: partial?
      }

      finish_event_response(processed, result, partial?, pages_fetched, opts)
    end
  end

  defp finish_event_response(%{persistence_errors: []} = processed, result, partial?, pages_fetched, opts) do
    mark_reconciliation(partial?, pages_fetched, opts)
    status = if processed.persistence_attempted?, do: :ok, else: :not_attempted
    {:ok, Map.put(result, :recent_merge_persistence, status)}
  end

  defp finish_event_response(%{persistence_errors: [reason | _]}, result, _partial?, _pages_fetched, _opts) do
    {:error, {:recent_merge_persistence, reason, result}}
  end

  defp fetch_backfill_pages(first_page, last_event_id, opts) do
    if saturated_page?(first_page) and watermark_missing?(first_page, last_event_id) do
      fetch_backfill_pages([first_page], 2, last_event_id, opts)
    else
      {:ok, %{pages: [first_page], partial?: false}}
    end
  end

  defp fetch_backfill_pages(pages, page, last_event_id, opts) when page <= @max_event_pages do
    client_opts =
      [page: page, per_page: @repo_events_per_page]
      |> maybe_put(:request_fun, Keyword.get(opts, :request_fun))

    case Client.fetch_repo_events(client_opts) do
      {:ok, {:events, events, _etag, _poll_interval}} ->
        pages = [events | pages]

        if saturated_page?(events) and watermark_missing?(events, last_event_id) do
          fetch_backfill_pages(pages, page + 1, last_event_id, opts)
        else
          {:ok, %{pages: Enum.reverse(pages), partial?: false}}
        end

      {:ok, {:not_modified, _etag, _poll_interval}} ->
        {:ok, %{pages: Enum.reverse(pages), partial?: false}}

      {:error, reason} ->
        Logger.warning("GithubFirehose backfill page=#{page} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_backfill_pages(pages, _page, _last_event_id, _opts) do
    {:ok, %{pages: Enum.reverse(pages), partial?: true}}
  end

  defp saturated_page?(events), do: length(events) >= @repo_events_per_page

  defp event_id_present?(events, event_id) when is_binary(event_id) do
    Enum.any?(events, &(Map.get(&1, "id") == event_id))
  end

  defp event_id_present?(_events, _event_id), do: false

  defp watermark_missing?(_events, nil), do: true
  defp watermark_missing?(events, event_id), do: not event_id_present?(events, event_id)

  defp events_since_watermark(pages, nil), do: Enum.flat_map(pages, & &1)

  defp events_since_watermark(pages, last_event_id) do
    pages
    |> Enum.flat_map(& &1)
    |> Enum.take_while(&(Map.get(&1, "id") != last_event_id))
  end

  defp newest_event_id([%{"id" => id} | _]) when is_binary(id), do: id
  defp newest_event_id(_events), do: nil

  defp process_events(events, opts) do
    Enum.reduce(events, %{count: 0, persistence_errors: [], persistence_attempted?: false}, fn event, acc ->
      persistence_result = persist_recent_merge(event, opts)
      publish_result = publish_one(event, opts)

      %{
        count: acc.count + if(match?({:ok, _, _}, publish_result), do: 1, else: 0),
        persistence_errors: maybe_add_persistence_error(acc.persistence_errors, persistence_result),
        persistence_attempted?: acc.persistence_attempted? or persistence_attempted?(persistence_result)
      }
    end)
  end

  defp persist_recent_merge(event, opts) do
    live? = not GithubKeys.pre_boot_event?(event, opts)

    normalize_opts = [
      live?: live?,
      run_id: Keyword.get(opts, :run_id, Boot.run_id()),
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      repo: Keyword.get(opts, :repo)
    ]

    case RecentMerge.from_github_event(event, normalize_opts) do
      :not_merge ->
        :not_merge

      {:ok, merge} ->
        call_recent_merge_store(merge, opts)

      {:error, reason} ->
        Logger.warning("GithubFirehose recent merge skipped: #{inspect(reason)}")
        {:malformed, reason}
    end
  end

  defp call_recent_merge_store(merge, opts) do
    case Keyword.get(opts, :recent_merge_fun) do
      fun when is_function(fun, 1) -> fun.(merge)
      _ -> RecentMergeStore.upsert(merge)
    end
  rescue
    error -> {:error, {:store_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:store_exit, reason}}
  end

  defp maybe_add_persistence_error(errors, {:error, reason}), do: errors ++ [reason]
  defp maybe_add_persistence_error(errors, _result), do: errors

  defp persistence_attempted?({:ok, _result}), do: true
  defp persistence_attempted?({:error, _reason}), do: true
  defp persistence_attempted?(_result), do: false

  defp mark_reconciliation(partial?, pages_fetched, opts) do
    case Keyword.get(opts, :recent_merge_reconciliation_fun) do
      fun when is_function(fun, 2) -> fun.(partial?, pages_fetched)
      _ -> RecentMergeStore.mark_reconciliation(partial?, pages_fetched)
    end
  rescue
    error -> Logger.warning("GithubFirehose reconciliation status failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("GithubFirehose reconciliation status exited: #{inspect(reason)}")
  end

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
