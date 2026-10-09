defmodule Aiur.AgentRunner.CommentContext do
  @moduledoc """
  Fetches and normalises GitHub comment context for agent bootstrap.

  Collects issue comments after the `## Agent Workpad` cutoff, PR review
  comments, formal changes-requested reviews, and unaddressed review threads after the latest workpad cutoff,
  then converts them to event maps suitable for the bootstrap digest. The
  `Sanitizer.scrub` pass is applied before events enter the digest.
  """

  require Logger

  alias Aiur.AgentRunner.BootstrapDigest
  alias Aiur.Events.{IdGenerator, Sanitizer}
  alias Aiur.{ExternalContent, Issue, Tracker}

  @doc """
  Return comment-context events for `issue`.

  Fetches issue and PR comments, applying the workpad cutoff to every comment
  source including unaddressed review threads. Results are deduped by
  `(topic, comment_id)`.
  """
  @spec events(Issue.t(), map()) :: [map()]
  def events(issue, fetchers \\ comment_context_fetchers())

  def events(%Issue{identifier: identifier}, fetchers)
      when is_binary(identifier) do
    {issue_events, cutoff} = issue_comment_context(identifier, fetchers)

    pr_events = pr_comment_context_events(identifier, fetchers, cutoff)

    Enum.uniq_by(issue_events ++ pr_events, &BootstrapDigest.bootstrap_event_key/1)
  end

  def events(_issue, _fetchers), do: []

  defp issue_comment_context(identifier, fetchers) do
    case fetchers.issue_comments.(identifier) do
      {:ok, comments} when is_list(comments) ->
        cutoff = latest_workpad_comment_datetime(comments)
        events = comments |> comments_after_workpad(cutoff) |> comments_to_events("ticket.#{identifier}.issue.commented")
        {events, cutoff}

      {:error, reason} ->
        Logger.warning("comment_context fetch_failed topic=ticket.#{identifier}.issue.commented reason=#{inspect(reason)}")
        {[incomplete_comment_context("ticket.#{identifier}.issue.commented", reason)], nil}
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
        pr_number,
        cutoff
      ) ++
      fetch_formal_review_events(
        "ticket.#{identifier}.pr.review_comment",
        Map.get(fetchers, :pr_reviews),
        pr_number,
        cutoff
      )
  end

  defp log_comment_context_open_pr_failed(identifier, reason) do
    Logger.warning("comment_context open_pr_failed identifier=#{identifier} reason=#{inspect(reason)}")
    []
  end

  defp comment_context_fetchers do
    %{
      issue_comments: &Tracker.fetch_classified_issue_comments/1,
      open_pr: &Aiur.CodeHost.fetch_open_pull_request_for_branch/1,
      pr_review_comments: &Aiur.CodeHost.fetch_classified_pr_review_comments/1,
      unaddressed_pr_review_thread_comments: &Aiur.CodeHost.fetch_unaddressed_pr_review_thread_comments/1,
      pr_reviews: &Aiur.CodeHost.fetch_classified_pr_reviews/1
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
        [incomplete_comment_context(topic, reason)]
    end
  end

  defp incomplete_comment_context(topic, reason) do
    message = "comment context incomplete: " <> ExternalContent.wrap(inspect(reason), :comment_body, nil)
    %{id: IdGenerator.next_id(), topic: topic, source: :system, message: message}
  end

  defp fetch_unaddressed_review_thread_events(_topic, nil, _pr_number, _cutoff), do: []

  defp fetch_unaddressed_review_thread_events(topic, fetch_fun, pr_number, cutoff)
       when is_function(fetch_fun, 1) do
    case fetch_fun.(pr_number) do
      {:ok, comments} when is_list(comments) ->
        comments
        |> comments_after_workpad(cutoff)
        |> comments_to_events(topic)

      {:error, reason} ->
        Logger.warning("comment_context fetch_failed topic=#{topic} source=unaddressed_review_threads reason=#{inspect(reason)}")
        []
    end
  end

  defp fetch_formal_review_events(_topic, nil, _pr_number, _cutoff), do: []

  defp fetch_formal_review_events(topic, fetch_fun, pr_number, cutoff) when is_function(fetch_fun, 1) do
    case fetch_fun.(pr_number) do
      {:ok, reviews} when is_list(reviews) ->
        reviews
        |> latest_actionable_review_per_reviewer()
        |> Enum.filter(&review_after_workpad?(&1, cutoff))
        |> comments_to_events(topic)

      {:error, reason} ->
        Logger.warning("comment_context fetch_failed topic=#{topic} source=formal_reviews reason=#{inspect(reason)}")
        []
    end
  end

  defp latest_actionable_review_per_reviewer(reviews) do
    reviews
    |> Enum.filter(&(is_binary(comment_author(&1)) and match?(%DateTime{}, parse_comment_datetime(Map.get(&1, "submitted_at")))))
    |> Enum.group_by(&comment_author/1)
    |> Enum.flat_map(fn {_author, submitted} -> latest_actionable_review(submitted) end)
  end

  defp latest_actionable_review(submitted) do
    submitted
    |> Enum.sort_by(&Map.fetch!(&1, "submitted_at"), :desc)
    |> Enum.find(&(actionable_review?(&1) or Map.get(&1, "state") in ["APPROVED", "DISMISSED"]))
    |> case do
      %{} = review -> if(actionable_review?(review), do: [review], else: [])
      _ -> []
    end
  end

  defp actionable_review?(%{"state" => "CHANGES_REQUESTED", "body" => body}) when is_binary(body) and body != "", do: true
  defp actionable_review?(%{"state" => "COMMENTED", "body" => body}) when is_binary(body) and body != "", do: true
  defp actionable_review?(_review), do: false

  defp review_after_workpad?(_review, nil), do: true

  defp review_after_workpad?(review, %DateTime{} = cutoff) do
    case parse_comment_datetime(Map.get(review, "submitted_at")) do
      %DateTime{} = submitted -> DateTime.compare(submitted, cutoff) == :gt
      nil -> false
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
        # Ownership can now be *unknown* (`nil`) when a quota hold blocks the
        # CODEOWNERS lookup. Unknown is not trusted, and the payload stays a
        # boolean so downstream matches on `false` still hold.
        author_trusted?: Map.get(comment, :authoritative) == true
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
