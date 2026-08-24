defmodule Aiur.GitHub.GraphQLCostTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{BotIdentity, CIPollBatch, CommentPollBatch, GraphQLCost, Transport}

  @lib_root Path.expand("../../../lib", __DIR__)

  describe "instrument/1" do
    test "adds the selection to a named query's top-level selection set" do
      query = """
      query AiurThing($owner: String!) {
        repository(owner: $owner, name: "r") { id }
      }
      """

      instrumented = GraphQLCost.instrument(query)

      assert instrumented =~ "rateLimit { limit cost remaining resetAt }"
      # Top level, not nested: the selection must resolve on `Query`, and a
      # `rateLimit` inside `repository` is not a field that exists.
      assert top_level_selection?(instrumented, "rateLimit")
    end

    test "adds the selection to a shorthand query" do
      instrumented = GraphQLCost.instrument("{ viewer { login } }")

      assert instrumented =~ "rateLimit {"
      assert top_level_selection?(instrumented, "rateLimit")
    end

    test "is idempotent, so an already-priced query is untouched" do
      query = "query A { rateLimit { cost } viewer { login } }"

      assert GraphQLCost.instrument(query) == query
    end

    test "a field merely named like rateLimit does not count as already priced" do
      query = "query A { repository { rateLimitStatus { id } } }"

      instrumented = GraphQLCost.instrument(query)

      # A substring check would decline here and leave the query billed at one
      # assumed point, which is the understatement the ranking exists to remove.
      assert top_level_selection?(instrumented, "rateLimit")
      assert instrumented =~ "rateLimitStatus"
    end

    test "places the selection by bytes, so a multi-byte character cannot shift it" do
      # `selection_offset/4` counts bytes. Splitting by graphemes would move the
      # cut earlier by (bytes - graphemes) and splice the selection into the
      # middle of the first field name — a working query turned into a 400.
      for query <- [
            ~s|query A($q: String = "repo:o/r é ü") { search { id } }|,
            ~s|query A($q: String = "🎉🎉") { viewer { login } }|,
            ~s|query A($q: String = "éé") { viewer { login } }|,
            "# a leading comment — with an em dash\nquery A { viewer { login } }",
            ~s|{ search(query: "日本語テキスト") { id } }|
          ] do
        instrumented = GraphQLCost.instrument(query)

        assert top_level_selection?(instrumented, "rateLimit")

        # Nothing of the original document may be lost or reordered: removing the
        # injected selection must give back exactly what was passed in.
        assert String.replace(instrumented, "\n  " <> GraphQLCost.selection(), "") == query
      end
    end

    test "declines mutations, because rateLimit is a field on Query" do
      mutation = """
      mutation AiurResolve($threadId: ID!) {
        resolveReviewThread(input: {threadId: $threadId}) { clientMutationId }
      }
      """

      assert GraphQLCost.instrument(mutation) == mutation
      refute GraphQLCost.instrument(mutation) =~ "rateLimit"
    end

    test "declines subscriptions and fragment-led documents" do
      subscription = "subscription S { thing { id } }"
      fragment_led = "fragment F on Issue { id }\nquery Q { issue { ...F } }"

      assert GraphQLCost.instrument(subscription) == subscription
      assert GraphQLCost.instrument(fragment_led) == fragment_led
    end

    test "is not fooled by a brace inside a variable default value" do
      query = ~s|query A($filter: Filter = {state: OPEN}) { repository { id } }|

      instrumented = GraphQLCost.instrument(query)

      # The `{` opening the default value is inside parentheses and is not the
      # operation's selection set. Injecting there would produce
      # `{rateLimit ... state: OPEN}` and break the request outright.
      assert instrumented =~ ~s|{state: OPEN}|
      assert top_level_selection?(instrumented, "rateLimit")
    end

    test "is not fooled by braces inside strings or comments" do
      query = ~s|# a comment with { in it\nquery A { repository(name: "a{b") { id } }|

      instrumented = GraphQLCost.instrument(query)

      assert instrumented =~ ~s|"a{b"|
      assert top_level_selection?(instrumented, "rateLimit")
    end

    test "returns anything it cannot place unchanged rather than guessing" do
      for input <- ["", "not a graphql document", "query", nil, 42] do
        assert GraphQLCost.instrument(input) == input
      end
    end

    test "adds exactly one balanced selection set" do
      query = "query A($x: Int) { a { b { c } } }"

      instrumented = GraphQLCost.instrument(query)

      assert open_braces(instrumented) == open_braces(query) + 1
      assert close_braces(instrumented) == close_braces(query) + 1
    end
  end

  describe "reported/1" do
    test "reads the cost block GitHub put in the response body" do
      response = %{status: 200, body: %{"data" => %{"rateLimit" => %{"cost" => 26, "remaining" => 4974, "limit" => 5000, "resetAt" => "2026-08-17T13:00:00Z"}}}}

      assert GraphQLCost.reported(response) == %{
               cost: 26,
               remaining: 4974,
               limit: 5000,
               reset_at: "2026-08-17T13:00:00Z"
             }
    end

    test "answers nil when the query did not ask, so the call stays visibly unpriced" do
      for response <- [
            %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "bot"}}}},
            %{status: 200, body: %{}},
            %{status: 502, body: "gateway"},
            %{}
          ] do
        assert GraphQLCost.reported(response) == nil
      end
    end

    test "refuses a nonsense cost rather than recording it" do
      # A negative or non-integer cost is not a cheap call, it is a broken
      # reading, and recording it would corrupt the very total the ranking is
      # checked against.
      assert %{cost: nil} = GraphQLCost.reported(%{body: %{"data" => %{"rateLimit" => %{"cost" => -3}}}})
      assert %{cost: nil} = GraphQLCost.reported(%{body: %{"data" => %{"rateLimit" => %{"cost" => "26"}}}})
    end
  end

  describe "derive/1" do
    test "prefers the caller the call site declared" do
      assert GraphQLCost.derive(%{caller: :comment_poll_batch}) == "comment_poll_batch"
      assert GraphQLCost.derive(%{caller: "build_order_catalog"}) == "build_order_catalog"
    end

    test "falls back to the GraphQL operation name" do
      request = %{body: %{"query" => "query AiurCIPollBatch($owner: String!) { x }"}}

      assert GraphQLCost.derive(request) == "graphql:AiurCIPollBatch"
    end

    test "collapses REST routes to a shape so one call site is one row" do
      shape =
        GraphQLCost.derive(%{
          method: :get,
          url: "https://api.github.com/repos/o/r/issues/2073/comments"
        })

      assert shape == "rest:GET /repos/o/r/issues/:n/comments"

      # The same route for a different ticket must not become a second row, or
      # a hot path ranks below the noise it is spread across.
      assert GraphQLCost.derive(%{method: :get, url: "https://api.github.com/repos/o/r/issues/1999/comments"}) ==
               shape
    end

    test "never answers nil, so an unnamed call site is still a named row" do
      assert GraphQLCost.derive(%{}) == "unattributed"
    end
  end

  describe "transport integration" do
    test "prices the query and stamps the caller without adding a request" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      request_fun = fn request ->
        Agent.update(agent, &[request | &1])
        {:ok, %{status: 200, body: %{"data" => %{"rateLimit" => %{"cost" => 7}}}}}
      end

      assert {:ok, _body} =
               Transport.github_graphql(request_fun, "t", "query A { viewer { login } }", %{}, caller: :probe)

      requests = Agent.get(agent, & &1)

      # The whole claim of this unit: pricing is free. One call in, one call out.
      assert length(requests) == 1

      [request] = requests
      assert request.caller == "probe"
      assert request.body["query"] =~ "rateLimit {"
    end
  end

  describe "caller coverage" do
    test "every GraphQL call site in the tree declares a caller" do
      sources =
        @lib_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "github/transport.ex"))

      # An empty scan and a fully-declared tree both produce `[]`, so the guard
      # asserts it still finds the call sites first. Without this, renaming the
      # transport function silently retires the check while leaving it green.
      found = Enum.reduce(sources, 0, &(&2 + call_site_count(&1)))
      assert found >= 10, "the call-site scan found only #{found} sites; the guard has stopped matching"

      undeclared = Enum.flat_map(sources, &undeclared_call_sites/1)

      # A call site that does not declare itself is billed to the operation
      # name, which is better than `unattributed` but is not a promise. This
      # guard is what keeps the fourteenth query from being added unpriced and
      # quietly understating the very ranking it belongs in.
      assert undeclared == [],
             "GraphQL call sites without `caller:`:\n" <> Enum.join(undeclared, "\n")
    end

    test "the comment poll batch prices its real query" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

      request_fun = fn %{body: body} = request ->
        assert request.caller == "comment_poll_batch"
        assert top_level_selection?(body["query"], "rateLimit")
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{}}}}}
      end

      assert {:ok, _batch} = CommentPollBatch.fetch(["42"], request_fun: request_fun, token: "t")
    end

    test "the bot identity lookup prices its real query" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_bot_account: nil
      )

      request_fun = fn %{body: body} = request ->
        assert request.caller == "bot_identity"
        assert top_level_selection?(body["query"], "rateLimit")
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "bot"}}}}}
      end

      assert BotIdentity.bot_account([], request_fun, "token") == {:ok, "bot"}
    end
  end

  describe "estimate/1" do
    test "multiplies nested page sizes the way GitHub bills them" do
      query = """
      query AiurNested {
        repository(owner: "o", name: "r") {
          pullRequests(first: 2) {
            pageInfo { hasNextPage }
            nodes { number commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 30) { nodes { __typename } } } } } } }
          }
        }
      }
      """

      # 2 pull requests + 2 x 1 commit + 2 x 1 x 30 contexts.
      assert %{nodes: 64, points: 1, priceable?: true} = GraphQLCost.estimate(query)
    end

    test "an unpaged selection set costs nothing, so pageInfo and fragments are free" do
      assert %{nodes: 0, points: 1} = GraphQLCost.estimate("query A { repository { id owner { login } } }")
    end

    test "prices in points at a hundred nodes each, never below one" do
      assert %{nodes: 100, points: 1} = GraphQLCost.estimate("query A { repository { issues(first: 100) { nodes { id } } } }")
      assert %{nodes: 250, points: 3} = GraphQLCost.estimate("query A { repository { issues(first: 250) { nodes { id } } } }")
    end

    test "a page size behind a variable is reported unpriceable rather than guessed at" do
      query = "query A($pageSize: Int!) { repository { issues(first: $pageSize) { nodes { id } } } }"

      assert %{priceable?: false} = GraphQLCost.estimate(query)
    end

    test "a page size inside a string literal is not read as structure" do
      query = ~s|query A { search(query: "first: 100 {", type: ISSUE, first: 5) { nodes { __typename } } }|

      assert %{nodes: 5, priceable?: true} = GraphQLCost.estimate(query)
    end
  end

  describe "check/2" do
    test "refuses a document that asks for more points than the ceiling" do
      # The shape the cuts removed: a hundred branch aliases each dragging a
      # nested connection behind them, which is how one document came to cost a
      # tenth of the hourly budget.
      query = "query A { repository { " <> String.duplicate(over_budget_alias(), 100) <> " } }"

      assert {:error, {:graphql_cost_ceiling, details}} = GraphQLCost.check(query, caller: "test", ceiling_points: 250)
      assert details.points > details.ceiling_points
      assert details.operation == "A"
      assert details.caller == "test"
    end

    test "passes a document inside the ceiling" do
      assert GraphQLCost.check("query A { repository { issues(first: 50) { nodes { id } } } }") == :ok
    end

    # The default has to sit far above every document this tree sends, because
    # the estimate is a node count and GitHub bills these documents far cheaper
    # (the CI poll batch bills 1 point where the arithmetic says ~510). Only a
    # shape that has gone genuinely pathological trips it.
    test "the default ceiling only trips on a pathological fan-out" do
      assert GraphQLCost.check("query A { repository { " <> String.duplicate(over_budget_alias(), 100) <> " } }") == :ok

      pathological = "query A { repository { " <> String.duplicate(over_budget_alias(), 10_000) <> " } }"

      assert {:error, {:graphql_cost_ceiling, _details}} = GraphQLCost.check(pathological)
    end

    test "never refuses an unpriceable document, because the number was never read" do
      query = "query A($pageSize: Int!) { repository { issues(first: $pageSize) { nodes { id } } } }"

      assert GraphQLCost.check(query, ceiling_points: 1) == :ok
    end

    test "the ceiling is configurable" do
      query = "query A { repository { issues(first: 500) { nodes { id } } } }"

      assert GraphQLCost.check(query, ceiling_points: 100) == :ok
      assert {:error, {:graphql_cost_ceiling, _details}} = GraphQLCost.check(query, ceiling_points: 4)
    end
  end

  # The ceiling is a shape guard, and a shape guard that refuses real traffic is
  # an outage. The batches are the largest documents this tree sends, so if the
  # ceiling is ever tightened toward the node estimate these fail first — which
  # is the point, because measured GitHub billing is 1 point for the CI poll
  # batch and 8 for the comment poll batch at its shipped
  # `reviewThreads(first: 20)` shape, not the ~510 and ~15 the node arithmetic
  # predicts.
  describe "the ceiling never refuses real traffic" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
      :ok
    end

    test "a full CI poll batch document passes the ceiling with room to spare" do
      assert_within_ceiling(&CIPollBatch.fetch/2)
    end

    test "a full comment poll batch document passes the ceiling with room to spare" do
      assert_within_ceiling(&CommentPollBatch.fetch/2)
    end
  end

  defp assert_within_ceiling(fetch) do
    query = batch_document(fetch)

    assert GraphQLCost.check(query) == :ok
    assert GraphQLCost.estimate(query).points * 10 < GraphQLCost.ceiling_points()
  end

  # A page size big enough that forty of these aliases clear any sane ceiling.
  defp over_budget_alias do
    "a: pullRequests(first: 100) { nodes { commits(last: 5) { nodes { commit { id } } } } } "
  end

  # Drives the real batch over a full chunk's worth of targets and returns the
  # document it actually builds, so the guard cannot drift from the query.
  defp batch_document(fetch) do
    parent = self()

    request_fun = fn %{body: body} ->
      send(parent, {:query, body["query"]})
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{}}}}}
    end

    targets = Enum.map(1..60, &to_string/1)
    assert {:ok, _batch} = fetch.(targets, request_fun: request_fun, token: "t")

    assert_received {:query, query}
    query
  end

  defp call_site_count(path) do
    path |> File.read!() |> then(&Regex.scan(call_site_pattern(), &1)) |> length()
  end

  defp call_site_pattern, do: ~r/Transport\.github_graphql(?:_response)?\(/

  defp undeclared_call_sites(path) do
    source = File.read!(path)

    call_site_pattern()
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, _length} | _] -> {start, call_text(source, start)} end)
    |> Enum.reject(fn {_start, text} -> String.contains?(text, "caller:") end)
    |> Enum.map(fn {start, _text} ->
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      "#{Path.relative_to(path, @lib_root)}:#{line}"
    end)
  end

  # The argument list of the call beginning at `start`, found by balancing
  # parentheses. Cheaper than parsing the file and exact enough for a guard.
  defp call_text(source, start) do
    source
    |> binary_part(start, byte_size(source) - start)
    |> balanced_call()
  end

  defp balanced_call(text), do: balanced_call(text, 0, 0, [])

  defp balanced_call(<<>>, _index, _depth, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp balanced_call(<<?(, rest::binary>>, index, depth, acc),
    do: balanced_call(rest, index + 1, depth + 1, [?( | acc])

  defp balanced_call(<<?), rest::binary>>, index, depth, acc) do
    if depth == 1, do: acc |> Enum.reverse() |> IO.iodata_to_binary(), else: balanced_call(rest, index + 1, depth - 1, [?) | acc])
  end

  defp balanced_call(<<char::utf8, rest::binary>>, index, depth, acc),
    do: balanced_call(rest, index + 1, depth, [<<char::utf8>> | acc])

  # True when `field` appears at brace depth 1 — the operation's own selection
  # set — rather than nested inside another field's.
  defp top_level_selection?(document, field) when is_binary(document) do
    document
    |> String.replace(~r/"[^"]*"/, ~s(""))
    |> String.replace(~r/#[^\n]*/, "")
    |> depth_map()
    |> Enum.any?(fn {chunk, depth} -> depth == 1 and String.contains?(chunk, field) end)
  end

  defp depth_map(document) do
    document
    |> String.graphemes()
    |> Enum.reduce({[], 0, ""}, fn
      "{", {chunks, depth, current} -> {[{current, depth} | chunks], depth + 1, ""}
      "}", {chunks, depth, current} -> {[{current, depth} | chunks], max(depth - 1, 0), ""}
      char, {chunks, depth, current} -> {chunks, depth, current <> char}
    end)
    |> then(fn {chunks, depth, current} -> [{current, depth} | chunks] end)
  end

  defp open_braces(document) when is_binary(document),
    do: document |> String.graphemes() |> Enum.count(&(&1 == "{"))

  defp close_braces(document) when is_binary(document),
    do: document |> String.graphemes() |> Enum.count(&(&1 == "}"))
end
