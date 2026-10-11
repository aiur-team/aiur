defmodule Aiur.BuildOrder.GitHubGraphFixtures do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}

  def base_opts(response_or_request_fun, overrides \\ []) do
    request_fun =
      if is_function(response_or_request_fun, 1) do
        response_or_request_fun
      else
        queued_responses([response_or_request_fun])
      end

    [
      repository: @repository,
      request_fun: request_fun,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4
    ]
    |> Keyword.merge(overrides)
  end

  def public_opts(request_fun), do: [request_fun: request_fun]

  def queued_responses(responses) do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      send(parent, {:graph_request, request.body["variables"]})

      Agent.get_and_update(agent, fn
        [response | rest] -> {response, rest}
        [] -> raise "unexpected GraphQL request"
      end)
    end
  end

  def drain_requests, do: drain_requests([])

  def drain_requests(acc) do
    receive do
      {:graph_request, variables} -> drain_requests([variables | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def costed_catalog_response(nodes, total, cost, opts) do
    graphql_response(%{
      "data" => %{
        "rateLimit" => %{"limit" => 5000, "cost" => cost, "remaining" => 4000, "resetAt" => "2026-08-10T19:00:25Z"},
        "repository" => %{"issues" => connection(nodes, total, opts)}
      }
    })
  end

  def catalog_response(nodes, total, opts \\ []) do
    graphql_response(%{"data" => %{"repository" => %{"issues" => connection(nodes, total, opts)}}})
  end

  def selected_response(root, members, total, opts \\ []) do
    root = Map.put(root, "subIssues", connection(members, total, opts))
    graphql_response(%{"data" => %{"repository" => %{"issue" => root}}})
  end

  def graphql_response(body), do: {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "99"}], body: body}}
  def graphql_error, do: {:ok, %{status: 200, body: %{"errors" => [%{"message" => "redacted"}]}}}

  def connection(nodes, total, opts) do
    %{
      "nodes" => nodes,
      "totalCount" => total,
      "pageInfo" => %{
        "hasNextPage" => Keyword.get(opts, :has_next?, false),
        "endCursor" => Keyword.get(opts, :cursor)
      }
    }
  end

  def without_terminal_cursor({:ok, %{body: body} = response}, path) do
    {:ok, %{response | body: update_in(body, path, &without_terminal_cursor/1)}}
  end

  def without_terminal_cursor(connection) do
    update_in(connection, ["pageInfo"], &Map.delete(&1, "endCursor"))
  end

  def root(number, owner \\ "owner", repo \\ "repo") do
    issue_node(number, owner, repo)
    |> Map.put("labels", labels(["build-order"]))
  end

  # The catalog query's `subIssues` node shape: lifecycle only. Buying a
  # `labels` connection per member here is what cost 26 points a page (#1766),
  # so fixtures must not hand the normalizer labels the real query never gets.
  def catalog_member(number) do
    number |> issue_node() |> Map.take(["state", "stateReason"])
  end

  # The `subIssues` node shape of the opt-in labelled catalog read: lifecycle
  # plus the per-member `labels` connection that resolves lane and phase.
  def labelled_catalog_member(number, label_names) do
    number |> catalog_member() |> Map.put("labels", labels(label_names))
  end

  # The `nodes { ... }` line inside the catalog query's `subIssues` block — the
  # only place the expensive per-member connection can appear.
  def catalog_sub_issues_selection(query) do
    lines = String.split(query, "\n")
    start = Enum.find_index(lines, &String.contains?(&1, "subIssues(first: 100)"))

    # The member selection is the whole `nodes { ... }` block under `subIssues`,
    # balanced across its nested braces. It is multi-line now that the catalog
    # member carries identity scalars for the reconciliation deposit (#2313),
    # so a single `nodes {` line no longer represents it.
    lines
    |> Enum.drop(start)
    |> Enum.drop_while(&(not String.contains?(&1, "nodes {")))
    |> take_balanced_braces()
    |> Enum.join("\n")
    |> String.trim()
  end

  def take_balanced_braces(lines) do
    {selected, _depth} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, depth} ->
        depth = depth + brace_delta(line)
        acc = [line | acc]

        if depth == 0,
          do: {:halt, {Enum.reverse(acc), depth}},
          else: {:cont, {acc, depth}}
      end)

    selected
  end

  def brace_delta(line) do
    chars = String.to_charlist(line)
    Enum.count(chars, &(&1 == ?{)) - Enum.count(chars, &(&1 == ?}))
  end

  def member(number, root, opts \\ []) do
    issue_node(number)
    |> Map.put("parent", endpoint_from(root))
    |> Map.put("labels", labels(Keyword.get(opts, :labels, ["phase:2", "build-lane:plan-graph", "complexity:4"])))
    |> Map.put("blockedBy", dependency_connection(Keyword.get(opts, :blocked_by, [])))
    |> Map.put("blocking", dependency_connection(Keyword.get(opts, :blocking, [])))
  end

  def issue_node(number, owner \\ "owner", repo \\ "repo") do
    %{
      "id" => "I#{owner}-#{repo}-#{number}",
      "databaseId" => number,
      "number" => number,
      "title" => "Issue #{number}",
      "url" => "https://github.com/#{owner}/#{repo}/issues/#{number}",
      "state" => if(rem(number, 2) == 0, do: "CLOSED", else: "OPEN"),
      "stateReason" => if(rem(number, 2) == 0, do: "COMPLETED", else: nil),
      "createdAt" => "2026-07-13T12:00:00Z",
      "updatedAt" => "2026-07-13T12:30:00Z",
      "repository" => repository(owner, repo),
      "parent" => nil,
      "labels" => labels(["build-order"])
    }
  end

  def endpoint(number, owner \\ "owner", repo \\ "repo"), do: endpoint_from(issue_node(number, owner, repo))

  def endpoint_from(node) do
    Map.take(node, ["id", "databaseId", "number", "url", "repository"])
  end

  def contradictory_locators(root) do
    endpoint = endpoint_from(root)

    [
      {:database_id, Map.put(endpoint, "databaseId", 999)},
      {:number, endpoint |> Map.put("number", 999) |> Map.put("url", "https://github.com/owner/repo/issues/999")},
      {:url, Map.put(endpoint, "url", "https://github.com/owner/repo/issues/999")}
    ]
  end

  def identity(node, configured_repository \\ @repository) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{
          "node_id" => node["id"],
          "database_id" => node["databaseId"],
          "number" => node["number"],
          "repository" => node["repository"]
        },
        configured_repository,
        configured_repository
      )

    identity
  end

  def repository(owner, repo), do: %{"name" => repo, "owner" => %{"login" => owner}}
  def labels(names), do: connection(Enum.map(names, &%{"name" => &1}), length(names), [])
  def dependency_connection(nodes), do: connection(nodes, length(nodes), [])
end
