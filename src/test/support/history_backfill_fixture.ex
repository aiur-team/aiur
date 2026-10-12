defmodule Aiur.HistoryBackfillFixture do
  @moduledoc false
  @time "2026-10-08T10:00:00Z"
  def time, do: @time
  def ref(n, owner \\ "acme", repo \\ "widgets"), do: %{"number" => n, "repository" => %{"name" => repo, "owner" => %{"login" => owner}}}
  def blockers(refs, next \\ false, cursor \\ nil), do: %{"nodes" => refs, "totalCount" => length(refs), "pageInfo" => %{"hasNextPage" => next, "endCursor" => cursor}}

  def label(name, type \\ "LabeledEvent", at \\ @time, actor \\ "kev"),
    do: %{"__typename" => type, "createdAt" => at, "actor" => if(actor, do: %{"login" => actor}), "label" => %{"name" => name}}

  def node(n, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "I_#{n}",
        "number" => n,
        "title" => "Ticket #{n}",
        "state" => "CLOSED",
        "stateReason" => "COMPLETED",
        "createdAt" => @time,
        "updatedAt" => @time,
        "closedAt" => @time,
        "parent" => nil,
        "labels" => %{"nodes" => [%{"name" => "feature:home"}], "totalCount" => 1},
        "blockedBy" => blockers([]),
        "timelineItems" => timeline([label("feature:home"), label("agent:in-progress")])
      },
      extra
    )
  end

  def timeline(nodes, next \\ false), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next}}

  def page(nodes, next \\ false, cursor \\ nil, cost \\ 3, remaining \\ 4997, total \\ 6) do
    %{
      "data" => %{
        "rateLimit" => %{"limit" => 5000, "cost" => cost, "remaining" => remaining, "resetAt" => "2026-10-08T12:00:00Z"},
        "repository" => %{"issues" => %{"nodes" => nodes, "totalCount" => total, "pageInfo" => %{"hasNextPage" => next, "endCursor" => cursor}}}
      }
    }
  end

  def response(body), do: {:ok, %{status: 200, headers: [], body: body}}
end
