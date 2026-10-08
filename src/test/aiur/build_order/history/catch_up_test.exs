defmodule Aiur.BuildOrder.History.CatchUpTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.History.{CatchUp, CatchUpQuery}
  alias Aiur.GitHub.GraphQLCost
  @t ~U[2026-10-01 12:00:00Z]

  defp issue_node do
    %{
      "id" => "I_7",
      "number" => 7,
      "title" => "Closed",
      "state" => "CLOSED",
      "stateReason" => "COMPLETED",
      "createdAt" => DateTime.to_iso8601(@t),
      "closedAt" => DateTime.to_iso8601(@t),
      "updatedAt" => DateTime.to_iso8601(@t),
      "parent" => nil,
      "labels" => %{"totalCount" => 1, "nodes" => [%{"name" => "Agent:Done"}]},
      "blockedBy" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [%{"number" => 2, "repository" => %{"name" => "widgets", "owner" => %{"login" => "acme"}}}]}
    }
  end

  defp page(nodes, more \\ false, cursor \\ nil), do: {:ok, %{"data" => %{"repository" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}}}}}
  defp opts(fun), do: [graphql_fun: fun, token_fun: fn -> {:ok, "fake"} end, now_fun: fn -> @t end]

  test "query, caller and floor use explicit CLOSED recovery with overlap" do
    assert CatchUp.floor(%{"watermark" => DateTime.to_iso8601(@t)}, nil) == DateTime.add(@t, -600)
    assert CatchUp.floor(nil, %{"started_at" => DateTime.to_iso8601(@t)}) == @t
    assert CatchUp.floor(nil, nil) == :unknown
    assert GraphQLCost.estimate(CatchUpQuery.document()) == %{nodes: 13_100, points: 131, priceable?: true}

    fun = fn _request, "fake", query, vars, options ->
      assert query =~ "states:[CLOSED]"
      assert query =~ "direction:ASC"
      assert vars == %{"owner" => "acme", "name" => "widgets", "since" => DateTime.to_iso8601(@t), "after" => nil}
      assert options[:caller] == "build_history_catch_up"
      page([issue_node()])
    end

    result = CatchUp.run("acme/widgets", @t, opts(fun))
    assert %{status: :ok, pages: 1, watermark: @t} = result
    assert [%{fields: %{closed_at: @t, labels: ["agent:done"], parent: :none, blocked_by: [%{owner: "acme", repository: "widgets", number: 2}]}}] = result.events
  end

  test "truncated connections are omitted and malformed nodes refuse the run" do
    node = %{issue_node() | "labels" => %{"totalCount" => 31, "nodes" => []}, "blockedBy" => %{"pageInfo" => %{"hasNextPage" => true, "endCursor" => "next"}, "nodes" => []}}
    assert {:ok, event} = CatchUpQuery.node_to_event(node, repository: "acme/widgets", observed_at: @t)
    refute Map.has_key?(event.fields, :labels)
    refute Map.has_key?(event.fields, :blocked_by)
    assert {:ok, unknown} = CatchUpQuery.node_to_event(%{node | "closedAt" => nil, "stateReason" => nil}, observed_at: @t)
    assert unknown.fields.closed_at == :unknown
    assert unknown.fields.lifecycle.state_reason == :unknown
    assert CatchUp.run("acme/widgets", @t, opts(fn _, _, _, _, _ -> page([%{node | "updatedAt" => "bad"}]) end)).status == :failed
  end

  test "caps pagination at five pages and preserves the last node watermark" do
    fun = fn _, _, _, vars, _ ->
      index = if vars["after"], do: String.to_integer(vars["after"]) + 1, else: 1
      send(self(), {:page, index})
      page([%{issue_node() | "number" => index, "updatedAt" => DateTime.to_iso8601(DateTime.add(@t, index))}], true, to_string(index))
    end

    result = CatchUp.run("acme/widgets", @t, opts(fun))
    assert result.status == :partial
    assert result.pages == 5
    assert length(result.events) == 5
    assert result.watermark == DateTime.add(@t, 5)
    assert_received {:page, 5}
    refute_received {:page, 6}
  end

  test "later-page failure discards events and leaves watermark unset" do
    fun = fn _, _, _, vars, _ -> if vars["after"], do: {:error, :timeout}, else: page([issue_node()], true, "next") end
    result = CatchUp.run("acme/widgets", @t, opts(fun))
    assert result.status == :failed
    assert result.reason == {:github, :timeout, %{reason: :timeout}}
    assert result.events == []
    assert result.watermark == nil
    assert result.pages == 1
  end

  test "raw local hold is classified and waited out, long hold stays held" do
    Process.put(:attempt, 0)

    fun = fn _, _, _, _, _ ->
      count = Process.get(:attempt)
      Process.put(:attempt, count + 1)
      if count == 0, do: {:error, {:aiur, :locally_held, %{reset_at: DateTime.add(DateTime.utc_now(), 1)}}}, else: page([issue_node()])
    end

    result = CatchUp.run("acme/widgets", @t, opts(fun) ++ [local_hold_sleep_fun: fn ms -> send(self(), {:waited, ms}) end])
    assert result.status == :ok
    assert_received {:waited, ms}
    assert ms > 0
    assert Process.get(:attempt) == 2
    held = fn _, _, _, _, _ -> {:error, {:aiur, :locally_held, %{reset_at: DateTime.add(DateTime.utc_now(), 120)}}} end
    result = CatchUp.run("acme/widgets", @t, opts(held) ++ [local_hold_max_wait_ms: 1])
    assert result.status == :held
    assert result.events == []
  end

  test "partial runs resume the cursor even when every node has the same update timestamp" do
    fun = fn _, _, _, vars, _ ->
      index = if vars["after"], do: String.to_integer(vars["after"]) + 1, else: 1
      page([%{issue_node() | "number" => index}], index < 6, to_string(index))
    end

    first = CatchUp.run("acme/widgets", @t, opts(fun))
    assert first.status == :partial
    checkpoint = %{"watermark" => DateTime.to_iso8601(first.watermark), "continuation" => first.continuation}
    assert CatchUp.floor(checkpoint, nil) == @t
    second = CatchUp.run("acme/widgets", CatchUp.floor(checkpoint, nil), opts(fun) ++ [continuation: first.continuation])
    assert second.status == :ok
    assert second.pages == 1
    assert Enum.map(second.events, & &1.number) == [6]
    assert second.watermark == @t
  end

  test "malformed response, cursor loop and unavailable token fail closed" do
    for response <- [{:ok, %{}}, page([], true, "next"), page([issue_node()], true, nil)] do
      result = CatchUp.run("acme/widgets", @t, opts(fn _, _, _, _, _ -> response end))
      assert result.status == :failed
      assert result.watermark == nil
    end

    result = CatchUp.run("acme/widgets", @t, token_fun: fn -> {:error, :no_token} end)
    assert result.status == :failed
    assert result.reason == :no_token
  end
end
