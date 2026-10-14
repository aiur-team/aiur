defmodule Aiur.GitHub.DispatchAuthorization.TestFixtures do
  @moduledoc false

  alias Aiur.{AlertFeed, Issue}
  alias Aiur.GitHub.DispatchAuthorization

  def active_deferral_topics do
    AlertFeed.list(needs_attention: true)
    |> Enum.map(& &1["topic"])
    |> Enum.filter(&(is_binary(&1) and String.contains?(&1, "dispatch_authorization.deferred")))
    |> MapSet.new()
  end

  def fat_timeline(count, padding_bytes) do
    padding = String.duplicate("x", padding_bytes)

    for id <- 1..count do
      labeled_event(id, "agent:todo", "trusted", "2026-01-01T00:00:00Z")
      |> Map.put("body", padding)
    end
  end

  def encoded_size(events), do: byte_size(Jason.encode!(events))

  def query_value(url, key) do
    url
    |> URI.parse()
    |> Map.get(:query)
    |> Kernel.||("")
    |> URI.decode_query()
    |> Map.get(key)
  end

  def paged_timeline_request_fun(events) do
    total = length(events)

    fn %{url: url} = request ->
      per_page = url |> query_value("per_page") |> String.to_integer()
      page = url |> query_value("page") |> page_number()
      slice = Enum.slice(events, (page - 1) * per_page, per_page)
      last_page = div(total + per_page - 1, per_page)
      headers = next_page_headers(page, last_page, per_page)

      if encoded_size(slice) > request.max_response_bytes do
        {:ok, %{status: 200, body: "", headers: headers, private: %{aiur_response_too_large: true}}}
      else
        {:ok, %{status: 200, body: slice, headers: headers}}
      end
    end
  end

  def page_number(nil), do: 1
  def page_number(value), do: String.to_integer(value)

  def next_page_headers(page, last_page, per_page) when page < last_page do
    next = "https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=#{per_page}&page=#{page + 1}"
    [{"link", "<#{next}>; rel=\"next\""}]
  end

  def next_page_headers(_page, _last_page, _per_page), do: []

  def authorize_with_events(issue, events, allowed_users, extra_opts \\ []) do
    DispatchAuthorization.authorize(
      issue,
      "owner",
      "repo",
      "agent",
      Keyword.merge(
        [
          allowed_users: allowed_users,
          token: "test-token",
          request_fun: fn _request -> {:ok, %{status: 200, body: events}} end
        ],
        extra_opts
      )
    )
  end

  def issue(attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "42",
          identifier: "42",
          title: "Issue",
          state: "todo",
          creator_login: "outsider",
          dispatch_revision: "\"issue-42-v1\"",
          updated_at: ~U[2026-01-01 00:00:00Z]
        ],
        attrs
      )
    )
  end

  def labeled_event(id, label, actor, created_at) do
    %{
      "id" => id,
      "event" => "labeled",
      "label" => %{"name" => label},
      "actor" => %{"login" => actor},
      "created_at" => created_at
    }
  end
end
