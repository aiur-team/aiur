defmodule Aiur.RunTelemetry.GitHubEnricher do
  @moduledoc """
  Optional, generation-time GitHub anchors for telemetry reports.

  Enrichment is deliberately best-effort. Authentication, transport, and
  partial endpoint failures become sanitized report warnings while the local
  telemetry remains renderable. Comment bodies are inspected only long enough
  to apply the normal trust and benign-review rules and are never returned.
  """

  require Logger

  alias Aiur.GitHub.{AgentCommentOrigins, CodeOwners, Config, Transport}
  alias Aiur.Orchestrator.CommentWake
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.TicketBranch

  @max_pages 20

  @type result :: %{events: [map()], warnings: [map()]}

  @doc "Fetches GitHub lifecycle anchors for the supplied ticket identifiers."
  @spec enrich(String.t(), [String.t() | integer()], keyword()) :: result()
  def enrich(repo, tickets, opts \\ [])

  def enrich(repo, tickets, opts) when is_list(tickets) and is_list(opts) do
    with {:ok, {owner, name}} <- parse_repo(repo),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      ticket_set = tickets |> Enum.map(&to_string/1) |> MapSet.new()
      trusted_author_fun = Keyword.get(opts, :trusted_author_fun, &default_trusted_author?(&1, owner))
      comment_origin_resolver = Keyword.get(opts, :comment_origin_resolver, &AgentCommentOrigins.origin/2)

      case fetch_all(pulls_url(owner, name), request_fun, token, opts) do
        {:ok, pulls} ->
          matched = matching_pulls(pulls, ticket_set)
          boundary_events = Enum.flat_map(matched, &pull_events/1)

          {comment_events, warnings} =
            comment_events(%{
              owner: owner,
              name: name,
              ticket_set: ticket_set,
              matched: matched,
              request_fun: request_fun,
              token: token,
              trusted_author_fun: trusted_author_fun,
              comment_origin_resolver: comment_origin_resolver,
              opts: opts
            })

          %{
            events: normalize_events(boundary_events ++ comment_events),
            warnings: warnings
          }

        {:error, reason} ->
          %{events: [], warnings: [warning(:pull_requests, reason)]}
      end
    else
      {:error, :invalid_repo} ->
        %{events: [], warnings: [%{type: :github_enrichment_invalid_repo}]}

      {:error, reason} ->
        %{events: [], warnings: [warning(:authentication, reason)]}
    end
  rescue
    _error -> %{events: [], warnings: [warning(:enrichment, :unexpected_error)]}
  catch
    :exit, _reason -> %{events: [], warnings: [warning(:enrichment, :process_exit)]}
  end

  def enrich(_repo, _tickets, _opts),
    do: %{events: [], warnings: [%{type: :github_enrichment_invalid_repo}]}

  defp parse_repo(repo) when is_binary(repo) do
    case String.split(String.trim(repo), "/", parts: 2) do
      [owner, name]
      when owner != "" and name != "" ->
        if safe_repo_segment?(owner) and safe_repo_segment?(name) do
          {:ok, {owner, name}}
        else
          {:error, :invalid_repo}
        end

      _other ->
        {:error, :invalid_repo}
    end
  end

  defp parse_repo(_repo), do: {:error, :invalid_repo}
  defp safe_repo_segment?(segment), do: Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, segment)

  defp pulls_url(owner, name),
    do: "#{Transport.base_url()}/repos/#{owner}/#{name}/pulls?state=all&per_page=100"

  defp comments_url(owner, name, issue),
    do: "#{Transport.base_url()}/repos/#{owner}/#{name}/issues/#{issue}/comments?per_page=100"

  defp review_comments_url(owner, name, pull),
    do: "#{Transport.base_url()}/repos/#{owner}/#{name}/pulls/#{pull}/comments?per_page=100"

  defp reviews_url(owner, name, pull),
    do: "#{Transport.base_url()}/repos/#{owner}/#{name}/pulls/#{pull}/reviews?per_page=100"

  defp fetch_all(url, request_fun, token, opts) do
    max_pages = Keyword.get(opts, :max_pages, @max_pages)
    fetch_pages(url, request_fun, token, max_pages, [], [])
  end

  defp fetch_pages(_url, _request_fun, _token, pages_left, _seen, _items) when pages_left <= 0,
    do: {:error, :pagination_limit}

  defp fetch_pages(url, request_fun, token, pages_left, seen, items) do
    cond do
      url in seen ->
        {:error, :pagination_cycle}

      not safe_api_url?(url) ->
        {:error, :unsafe_pagination_url}

      true ->
        fetch_page(url, request_fun, token, pages_left, seen, items)
    end
  rescue
    _error -> {:error, :request_exception}
  catch
    :exit, _reason -> {:error, :request_exit}
  end

  defp fetch_page(url, request_fun, token, pages_left, seen, items) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        next_url = Transport.parse_next_page_url(Map.get(response, :headers, %{}))
        continue_pages(next_url, request_fun, token, pages_left, [url | seen], items ++ body)

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, status}

      {:ok, _response} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_pages(nil, _request_fun, _token, _pages_left, _seen, items), do: {:ok, items}

  defp continue_pages(next_url, request_fun, token, pages_left, seen, items) do
    fetch_pages(next_url, request_fun, token, pages_left - 1, seen, items)
  end

  defp safe_api_url?(url) when is_binary(url) do
    base = URI.parse(Transport.base_url())
    parsed = URI.parse(url)
    parsed.scheme == base.scheme and parsed.host == base.host
  end

  defp safe_api_url?(_url), do: false

  defp matching_pulls(pulls, ticket_set) do
    pulls
    |> Enum.flat_map(fn pull ->
      branch = get_in(pull, ["head", "ref"])
      ticket = TicketBranch.ticket_id(branch)

      if is_binary(ticket) and MapSet.member?(ticket_set, ticket) do
        [%{ticket: ticket, pull: pull}]
      else
        []
      end
    end)
  end

  defp pull_events(%{ticket: ticket, pull: pull}) do
    payload = pull_payload(pull)
    base = %{source: :github, author: get_in(pull, ["user", "login"]), pr: payload}

    opened =
      if is_binary(payload["created_at"]) do
        [Map.merge(base, %{id: "pr:#{payload["number"]}:opened", topic: "ticket.#{ticket}.pr.opened"})]
      else
        []
      end

    merged =
      if is_binary(payload["merged_at"]) do
        [Map.merge(base, %{id: "pr:#{payload["number"]}:merged", topic: "ticket.#{ticket}.pr.merged"})]
      else
        []
      end

    opened ++ merged
  end

  defp pull_payload(pull) do
    %{
      "number" => Map.get(pull, "number"),
      "created_at" => Map.get(pull, "created_at"),
      "merged_at" => Map.get(pull, "merged_at"),
      "closed_at" => Map.get(pull, "closed_at"),
      "user" => user_payload(Map.get(pull, "user"))
    }
  end

  defp comment_events(%{
         owner: owner,
         name: name,
         ticket_set: ticket_set,
         matched: matched,
         request_fun: request_fun,
         token: token,
         trusted_author_fun: trusted_author_fun,
         comment_origin_resolver: comment_origin_resolver,
         opts: opts
       }) do
    ticket_requests =
      Enum.map(ticket_set, fn ticket ->
        {comments_url(owner, name, ticket), :ticket_comments, ticket, "issue.commented"}
      end)

    pull_requests =
      Enum.flat_map(matched, fn %{ticket: ticket, pull: pull} ->
        number = Map.get(pull, "number")

        [
          {comments_url(owner, name, number), :pull_request_comments, ticket, "issue.commented"},
          {review_comments_url(owner, name, number), :review_comments, ticket, "pr.review_comment"},
          {reviews_url(owner, name, number), :reviews, ticket, "pr.review_comment"}
        ]
      end)

    (ticket_requests ++ pull_requests)
    |> Enum.reduce({[], []}, fn {url, endpoint, ticket, topic_suffix}, {events, warnings} ->
      case fetch_all(url, request_fun, token, opts) do
        {:ok, comments} ->
          normalized =
            comment_events_for_ticket(
              comments,
              ticket,
              topic_suffix,
              trusted_author_fun,
              comment_origin_resolver
            )

          {events ++ normalized, warnings}

        {:error, reason} ->
          {events, warnings ++ [warning(endpoint, reason)]}
      end
    end)
  end

  defp comment_events_for_ticket(
         comments,
         ticket,
         topic_suffix,
         trusted_author_fun,
         comment_origin_resolver
       ) do
    Enum.flat_map(comments, fn comment ->
      comment_event(comment, ticket, topic_suffix, trusted_author_fun, comment_origin_resolver)
    end)
  end

  defp comment_event(comment, ticket, topic_suffix, trusted_author_fun, comment_origin_resolver) when is_map(comment) do
    author = get_in(comment, ["user", "login"])
    trusted? = author_allowed?(trusted_author_fun, author)

    case comment_origin(ticket, comment, comment_origin_resolver) do
      {:ok, origin} ->
        candidate = %{
          id: "comment:#{Map.get(comment, "id")}",
          topic: "ticket.#{ticket}.#{topic_suffix}",
          source: :github,
          author: author,
          author_trusted?: trusted?,
          comment_origin: origin,
          comment: comment
        }

        if actionable_comment?(comment) and CommentWake.actionable_trusted_comment_event?(candidate) do
          [%{candidate | comment: comment_payload(comment)}]
        else
          []
        end

      {:error, reason} ->
        Logger.warning("github_enricher deferred unresolved comment origin: ticket=#{ticket} reason=#{inspect(reason)}")
        []
    end
  end

  defp comment_event(_comment, _ticket, _topic_suffix, _trusted_author_fun, _comment_origin_resolver), do: []

  @origin_results %{
    {:ok, :agent} => "agent",
    {:ok, "agent"} => "agent",
    {:ok, :external} => "external",
    {:ok, "external"} => "external",
    :agent => "agent",
    "agent" => "agent",
    :external => "external",
    "external" => "external"
  }

  defp comment_origin(ticket, comment, resolver) do
    resolver.(ticket, comment)
    |> normalize_origin_result()
  end

  defp normalize_origin_result({:error, reason}), do: {:error, reason}

  defp normalize_origin_result(result) do
    case Map.fetch(@origin_results, result) do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, {:invalid_origin_resolver_result, result}}
    end
  end

  defp comment_payload(comment) do
    submitted_at = Map.get(comment, "submitted_at")

    %{
      "id" => Map.get(comment, "id"),
      "created_at" => Map.get(comment, "created_at") || submitted_at,
      "updated_at" => Map.get(comment, "updated_at") || submitted_at || Map.get(comment, "created_at"),
      "review_thread_id" => Map.get(comment, "review_thread_id")
    }
  end

  defp actionable_comment?(comment) do
    body = Map.get(comment, "body")
    timestamp = Map.get(comment, "updated_at") || Map.get(comment, "created_at") || Map.get(comment, "submitted_at")

    not is_nil(Map.get(comment, "id")) and is_binary(timestamp) and timestamp != "" and
      is_binary(body) and String.trim(body) != ""
  end

  defp user_payload(user) when is_map(user), do: %{"login" => Map.get(user, "login")}
  defp user_payload(_user), do: nil

  defp author_allowed?(trusted_author_fun, author) when is_function(trusted_author_fun, 1) do
    trusted_author_fun.(author) == true
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp author_allowed?(_trusted_author_fun, _author), do: false

  defp default_trusted_author?(nil, _owner), do: false

  defp default_trusted_author?(author, owner) when is_binary(author) do
    if Process.whereis(CodeOwners) do
      CodeOwners.allowed?(author)
    else
      author_down = String.downcase(author)

      [owner, Config.bot_account() | Config.trusted_accounts()]
      |> Enum.filter(&is_binary/1)
      |> Enum.any?(&(String.downcase(&1) == author_down))
    end
  rescue
    _error -> String.downcase(author) == String.downcase(owner)
  catch
    :exit, _reason -> String.downcase(author) == String.downcase(owner)
  end

  defp normalize_events(events) do
    events
    |> Enum.uniq_by(fn event ->
      {event.topic, event.id, get_in(event, [:comment, "id"]), get_in(event, [:pr, "number"])}
    end)
    |> Enum.sort_by(&event_sort_key/1)
  end

  defp event_sort_key(event) do
    timestamp =
      get_in(event, [:comment, "updated_at"]) || get_in(event, [:comment, "created_at"]) ||
        get_in(event, [:pr, "merged_at"]) || get_in(event, [:pr, "created_at"]) || ""

    {timestamp, event.topic, to_string(event.id)}
  end

  defp warning(endpoint, reason) do
    %{
      type: :github_enrichment_failed,
      endpoint: endpoint,
      reason: Lifecycle.reason_class(reason)
    }
  end
end
