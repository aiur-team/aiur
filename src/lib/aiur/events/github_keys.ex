defmodule Aiur.Events.GithubKeys do
  @moduledoc """
  Shared key and topic helpers for GitHub-backed event detectors.

  The firehose, ls-remote ticker, and comments poller must classify refs and
  build dedup keys identically so whichever source sees an event first wins the
  same Publisher dedup race.
  """

  @pre_boot_buffer_seconds 60

  @doc """
  Converts a full Git ref into the event topic classification.

  Only canonical `refs/heads/aiur/<digits>` branches route to ticket push topics.
  Other single-segment branch refs route to system branch topics.
  """
  @spec ref_to_topic(term()) ::
          {:ticket, String.t(), String.t()} | {:system, String.t()} | nil
  def ref_to_topic(ref) when is_binary(ref) do
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

  def ref_to_topic(_), do: nil

  @doc """
  Returns the Publisher dedup key for push detectors.

  Invalid or incomplete values return nil so callers can either include a nil
  `:dedup_key` or omit the option entirely.
  """
  @spec push_dedup_key(term(), term(), term()) :: {String.t(), String.t(), String.t()} | nil
  def push_dedup_key(repo, ref, sha)
      when is_binary(repo) and repo != "" and is_binary(ref) and is_binary(sha),
      do: {repo, ref, sha}

  def push_dedup_key(_repo, _ref, _sha), do: nil

  @doc """
  Adds a push dedup key to keyword options only when the key is complete.
  """
  @spec put_push_dedup_key(keyword(), term(), term(), term()) :: keyword()
  def put_push_dedup_key(opts, repo, ref, sha) when is_list(opts) do
    case push_dedup_key(repo, ref, sha) do
      nil -> opts
      dedup_key -> Keyword.put(opts, :dedup_key, dedup_key)
    end
  end

  @doc """
  Returns the Publisher dedup key for PR lifecycle events.
  """
  @spec pr_dedup_key(term(), term(), term(), term()) ::
          {String.t(), String.t(), String.t()} | nil
  def pr_dedup_key(repo, pr_number, action, head_sha)
      when is_binary(repo) and is_integer(pr_number) and is_binary(action) and
             is_binary(head_sha),
      do: {repo, "pr:#{action}:#{pr_number}", head_sha}

  def pr_dedup_key(_repo, _pr_number, _action, _head_sha), do: nil

  @doc """
  Returns the Publisher dedup key for issue and PR comment events.
  """
  @spec comment_dedup_key(term(), term(), term(), term()) ::
          {String.t(), String.t(), String.t()} | nil
  def comment_dedup_key(repo, kind, parent_number, comment_id)
      when is_binary(repo) and is_binary(kind) and is_integer(parent_number) and
             is_integer(comment_id),
      do: {repo, "#{kind}:#{parent_number}", Integer.to_string(comment_id)}

  def comment_dedup_key(_repo, _kind, _parent_number, _comment_id), do: nil

  @doc """
  Returns the Publisher dedup key for unresolved PR review thread wakeups.

  The unaddressed-thread GraphQL path may not have a numeric comment
  `databaseId`, but GitHub's review thread node id is stable across replies.
  """
  @spec review_thread_dedup_key(term(), term(), term()) ::
          {String.t(), String.t(), String.t()} | nil
  def review_thread_dedup_key(repo, pr_number, thread_id)
      when is_binary(repo) and is_integer(pr_number) and is_binary(thread_id) and
             thread_id != "",
      do: {repo, "pr_review_thread:#{pr_number}", thread_id}

  def review_thread_dedup_key(_repo, _pr_number, _thread_id), do: nil

  @doc """
  Returns the GitHub event cutoff epoch for this boot window.
  """
  @spec boot_cutoff_epoch_seconds(keyword()) :: integer()
  def boot_cutoff_epoch_seconds(opts \\ []) do
    boot_epoch_seconds(opts) - @pre_boot_buffer_seconds
  end

  @doc """
  Returns the boot-window cutoff as an ISO8601 timestamp.
  """
  @spec boot_cutoff_iso8601(keyword()) :: String.t()
  def boot_cutoff_iso8601(opts \\ []) do
    opts
    |> boot_cutoff_epoch_seconds()
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  @doc """
  True when an Events API event was created before this boot window.
  """
  @spec pre_boot_event?(map(), keyword()) :: boolean()
  def pre_boot_event?(event, opts \\ [])

  def pre_boot_event?(event, opts) when is_map(event) do
    case event_created_at_epoch(event) do
      nil -> false
      created_at -> created_at < boot_cutoff_epoch_seconds(opts)
    end
  end

  def pre_boot_event?(_event, _opts), do: false

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
end
