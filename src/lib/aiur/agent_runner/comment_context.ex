defmodule Aiur.AgentRunner.CommentContext do
  @moduledoc """
  Fetches and normalises GitHub comment context for agent bootstrap.

  Collects issue comments after the `## Agent Workpad` cutoff, PR review
  comments, unaddressed review threads, and converts them to event maps
  suitable for the bootstrap digest. The `Sanitizer.scrub` pass and the
  workpad-cutoff + unaddressed-review-thread exception (#634→#642→#682) are
  preserved verbatim.
  """

  require Logger

  alias Aiur.AgentRunner.BootstrapDigest
  alias Aiur.Events.{IdGenerator, Sanitizer}
  alias Aiur.{Issue, Tracker}

  @doc """
  Return comment-context events for `issue`.

  Fetches issue and PR comments, applies the workpad cutoff, and collects
  unaddressed review threads regardless of that cutoff. Results are deduped
  by `(topic, comment_id)`.
  """
  @spec events(Issue.t(), map()) :: [map()]
  def events(issue, fetchers \\ comment_context_fetchers())

  def events(%Issue{identifier: identifier}, fetchers)
      when is_binary(identifier) do
    {issue_comments, cutoff} = issue_comment_context(identifier, fetchers)

    issue_events =
      issue_comments
      |> comments_after_workpad(cutoff)
      |> comments_to_events("ticket.#{identifier}.issue.commented")

    pr_events = pr_comment_context_events(identifier, fetchers, cutoff)

    Enum.uniq_by(issue_events ++ pr_events, &BootstrapDigest.bootstrap_event_key/1)
  end

  def events(_issue, _fetchers), do: []

  defp issue_comment_context(identifier, fetchers) do
    case fetchers.issue_comments.(identifier) do
      {:ok, comments} when is_list(comments) ->
        {comments, latest_workpad_comment_datetime(comments)}

      {:error, reason} ->
        Logger.warning("comment_context fetch_failed topic=ticket.#{identifier}.issue.commented reason=#{inspect(reason)}")
        {[], nil}
    end
  end

  defp pr_comment_context_events(identifier, fetchers, cutoff) do
    case fetchers.open_pr.(identifier) do
      {:ok, %{} = pr} -> pr_comment_context_events_for_pr(identifier, pr_number(pr), fetchers, cutoff)
      {:ok, nil} -> []
      {:error, reason} -> log_comment_context_open_pr_failed(identifier, reason)
    end
  end

  defp pr_comment_context_events_for_pr(_identifier, nil, _fetchers, _cutoff), do: []

  defp pr_comment_context_events_for_pr(identifier, pr_number, fetchers, cutoff) do
    fetch_comment_events(
      "ticket.#{identifier}.issue.commented",
      fn -> fetchers.issue_comments.(pr_number) end,
      cutoff
    ) ++
      fetch_comment_events(
        "ticket.#{identifier}.pr.review_comment",
        fn -> fetchers.pr_review_comments.(pr_number) end,
        cutoff
      ) ++
      fetch_unaddressed_review_thread_events(
        "ticket.#{identifier}.pr.review_comment",
        Map.get(fetchers, :unaddressed_pr_review_thread_comments),
        pr_number
      )
  end

  defp log_comment_context_open_pr_failed(identifier, reason) do
    Logger.warning("comment_context open_pr_failed identifier=#{identifier} reason=#{inspect(reason)}")
    []
  end

  defp comment_context_fetchers do
    %{
      issue_comments: &Tracker.fetch_classified_issue_comments/1,
      open_pr: &Tracker.fetch_open_pull_request_for_branch/1,
      pr_review_comments: &Tracker.fetch_classified_pr_review_comments/1,
      unaddressed_pr_review_thread_comments: &Tracker.fetch_unaddressed_pr_review_thread_comments/1
    }
  end

  defp fetch_comment_events(topic, fetch_fun, cutoff) when is_function(fetch_fun, 0) do
    case fetch_fun.() do
      {:ok, comments} when is_list(comments) ->
        comments
        |> comments_after_workpad(cutoff)
        |> comments_to_events(topic)

      {:error, reason} ->
        Logger.warning("comment_context fetch_failed topic=#{topic} reason=#{inspect(reason)}")
        []
    end
  end

  defp fetch_unaddressed_review_thread_events(_topic, nil, _pr_number), do: []

  defp fetch_unaddressed_review_thread_events(topic, fetch_fun, pr_number)
       when is_function(fetch_fun, 1) do
    case fetch_fun.(pr_number) do
      {:ok, comments} when is_list(comments) ->
        comments_to_events(comments, topic)

      {:error, reason} ->
        Logger.warning("comment_context fetch_failed topic=#{topic} source=unaddressed_review_threads reason=#{inspect(reason)}")
        []
    end
  end

  defp comments_to_events(comments, topic) when is_list(comments) do
    Enum.map(comments, &comment_context_event(topic, &1))
  end

  defp comments_after_workpad(comments, nil) when is_list(comments) do
    Enum.reject(comments, &workpad_comment?/1)
  end

  defp comments_after_workpad(comments, %DateTime{} = cutoff) when is_list(comments) do
    comments
    |> Enum.reject(&workpad_comment?/1)
    |> Enum.filter(&comment_after_cutoff?(&1, cutoff))
  end

  defp latest_workpad_comment_datetime(comments) when is_list(comments) do
    comments
    |> Enum.filter(&workpad_comment?/1)
    |> Enum.map(&comment_datetime/1)
    |> Enum.reject(&is_nil/1)
    |> latest_datetime()
  end

  defp latest_datetime([]), do: nil

  defp latest_datetime([first | rest]) do
    Enum.reduce(rest, first, fn datetime, latest ->
      if DateTime.compare(datetime, latest) == :gt, do: datetime, else: latest
    end)
  end

  defp workpad_comment?(comment) when is_map(comment) do
    comment
    |> comment_body()
    |> String.trim_leading()
    |> String.starts_with?("## Agent Workpad")
  end

  defp workpad_comment?(_comment), do: false

  defp comment_after_cutoff?(comment, %DateTime{} = cutoff) do
    case comment_datetime(comment) do
      %DateTime{} = datetime -> DateTime.compare(datetime, cutoff) == :gt
      nil -> true
    end
  end

  defp comment_datetime(comment) when is_map(comment) do
    value =
      Map.get(comment, "updated_at") ||
        Map.get(comment, :updated_at) ||
        Map.get(comment, "updatedAt") ||
        Map.get(comment, :updatedAt) ||
        Map.get(comment, "created_at") ||
        Map.get(comment, :created_at) ||
        Map.get(comment, "createdAt") ||
        Map.get(comment, :createdAt)

    parse_comment_datetime(value)
  end

  defp comment_datetime(_comment), do: nil

  defp parse_comment_datetime(%DateTime{} = datetime), do: datetime

  defp parse_comment_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_comment_datetime(_value), do: nil

  defp comment_context_event(topic, comment) do
    author = comment_author(comment)

    payload =
      %{
        comment: comment,
        source: :github,
        author: author,
        author_trusted?: Map.get(comment, :authoritative, false)
      }
      |> Sanitizer.scrub()

    summary = get_in(payload, [:comment, "body"]) || get_in(payload, [:comment, :body]) || ""

    payload
    |> Map.merge(%{
      id: comment_event_id(comment),
      topic: topic,
      summary: summary,
      message: summary
    })
  end

  defp comment_author(comment) when is_map(comment) do
    get_in(comment, ["user", "login"]) ||
      get_in(comment, [:user, :login]) ||
      get_in(comment, ["author", "login"]) ||
      get_in(comment, [:author, :login])
  end

  defp comment_author(_comment), do: nil

  defp comment_body(comment) when is_map(comment) do
    Map.get(comment, "body") || Map.get(comment, :body) || ""
  end

  defp comment_event_id(comment) when is_map(comment) do
    case Map.get(comment, "id") || Map.get(comment, :id) do
      id when is_integer(id) -> id
      _ -> IdGenerator.next_id()
    end
  end

  defp pr_number(pr) when is_map(pr) do
    case Map.get(pr, "number") || Map.get(pr, :number) do
      number when is_integer(number) -> number
      number when is_binary(number) -> number
      _ -> nil
    end
  end
end
