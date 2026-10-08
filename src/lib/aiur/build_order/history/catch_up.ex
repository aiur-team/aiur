defmodule Aiur.BuildOrder.History.CatchUp do
  @moduledoc "Bounded closed-issue catch-up; no writes until a run succeeds."
  alias Aiur.BuildOrder.History.{CatchUpQuery, Feed}
  alias Aiur.GitHub.{Errors, LocalHold, Transport}
  # ponytail: five pages and ten-minute overlap; tune only after measuring missed history.
  @max_pages 5

  @spec floor(map() | nil, map() | nil) :: DateTime.t() | :unknown
  def floor(closed, backfill) do
    case Feed.date(get_in(closed || %{}, ["continuation", "since"])) do
      %DateTime{} = since -> since
      _unknown -> watermark_floor(closed, backfill)
    end
  end

  defp watermark_floor(closed, backfill) do
    case Feed.date((closed || %{})["watermark"]) do
      %DateTime{} = watermark -> DateTime.add(watermark, -600, :second)
      _unknown -> Feed.date((backfill || %{})["started_at"])
    end
  end

  @spec run(String.t(), DateTime.t(), keyword()) :: map()
  def run(repo, since, opts \\ []) do
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()
    [owner, name] = String.split(repo, "/")
    continuation = Keyword.get(opts, :continuation) || %{}

    started =
      case Feed.date(continuation["started_at"]) do
        %DateTime{} = at -> at
        _unknown -> now
      end

    opts = Keyword.put(opts, :scan_started_at, started)
    variables = %{"owner" => owner, "name" => name, "since" => DateTime.to_iso8601(since), "after" => continuation["after"]}

    case Keyword.get(opts, :token_fun, &Transport.require_token/0).() do
      {:ok, token} -> pages(%{repo: repo, variables: variables, token: token, opts: opts, started: now, events: [], count: 0, cursors: MapSet.new()})
      {:error, reason} -> result(:failed, now, reason, 0, nil, [])
    end
  end

  defp pages(context) do
    %{variables: variables, token: token, opts: opts, started: started, count: count} = context
    graphql = Keyword.get(opts, :graphql_fun, &Transport.github_graphql/5)
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    attempt = fn ->
      case graphql.(request, token, CatchUpQuery.document(), variables, caller: "build_history_catch_up") do
        {:error, {:github, _kind, _detail}} = classified -> classified
        {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
        other -> other
      end
    end

    case LocalHold.run(attempt, LocalHold.caller_opts(opts)) do
      {:ok, %{"data" => %{"repository" => %{"issues" => connection}}}} ->
        apply_page(connection, %{context | count: count + 1})

      {:error, {:github, :local_hold, _detail} = reason} ->
        result(:held, started, reason, count, nil, [])

      {:error, reason} ->
        result(:failed, started, reason, count, nil, [])

      _other ->
        result(:failed, started, :invalid_catch_up_response, count, nil, [])
    end
  end

  defp apply_page(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}, context)
       when is_list(nodes) and is_boolean(more) do
    %{repo: repo, started: started, events: events, count: count, cursors: cursors} = context
    normalized = Enum.map(nodes, &CatchUpQuery.node_to_event(&1, repository: repo, observed_at: started))

    cond do
      Enum.any?(normalized, &match?({:error, _}, &1)) ->
        result(:failed, started, :invalid_catch_up_node, count, nil, [])

      more and (nodes == [] or not is_binary(cursor) or MapSet.member?(cursors, cursor)) ->
        result(:failed, started, :invalid_catch_up_cursor, count, nil, [])

      true ->
        events = events ++ Enum.map(normalized, &elem(&1, 1))

        next_page(more, cursor, %{context | events: events})
    end
  end

  defp apply_page(_page, context), do: result(:failed, context.started, :invalid_catch_up_page, context.count, nil, [])

  defp next_page(false, _cursor, context), do: result(:ok, context.started, nil, context.count, context.opts[:scan_started_at], context.events)

  defp next_page(true, cursor, %{count: @max_pages} = context) do
    result(:partial, context.started, nil, @max_pages, List.last(context.events).fields.updated_at, context.events)
    |> Map.put(:continuation, %{"after" => cursor, "since" => context.variables["since"], "started_at" => DateTime.to_iso8601(context.opts[:scan_started_at])})
  end

  defp next_page(true, cursor, context),
    do: pages(%{context | variables: %{context.variables | "after" => cursor}, cursors: MapSet.put(context.cursors, cursor)})

  defp result(status, at, reason, pages, watermark, events), do: %{status: status, at: at, reason: reason, pages: pages, watermark: watermark, events: events}
end
