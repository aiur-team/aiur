defmodule Aiur.GitHub.GraphQLCostTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{BotIdentity, CommentPollBatch, GraphQLCost, Transport}

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

    test "leaves brace balance unchanged" do
      query = "query A($x: Int) { a { b { c } } }"

      assert braces(GraphQLCost.instrument(query)) == braces(query) + 1
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
      undeclared =
        @lib_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "github/transport.ex"))
        |> Enum.flat_map(&undeclared_call_sites/1)

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

  defp undeclared_call_sites(path) do
    source = File.read!(path)

    ~r/Transport\.github_graphql(?:_response)?\(/
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

  defp braces(document) when is_binary(document),
    do: document |> String.graphemes() |> Enum.count(&(&1 == "{"))
end
