defmodule Aiur.LandingWatch.QuarantinePRTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.QuarantinePR

  @api "https://api.github.com/repos/test-org/test-repo"
  @commit String.duplicate("c", 40)
  @base String.duplicate("b", 40)
  @reaper "Aiur.Claude.Repl.ReaperTest :: stop_session/1 reports cleanup unknown while the process group remains alive"

  test "creates one list-entry commit, opens a PR with the ticket and run links, and enables auto-merge" do
    parent = self()

    observations = [
      %{
        pr: nil,
        run_url: "https://github.com/test-org/test-repo/actions/runs/39136290707/job/117701756559",
        checked_paths: ["src/lib/aiur/one.ex"]
      },
      %{pr: 5108, run_url: "https://github.com/test-org/test-repo/actions/runs/39136853814", checked_paths: ["src/lib/aiur/two.ex"]}
    ]

    assert {:ok, %{"number" => 901}} =
             QuarantinePR.open(
               %{identity: @reaper, observations: observations},
               4786,
               opts(parent, &response/2, fn -> {:ok, "# Existing entries\n"} end)
             )

    assert_received {:request, :post, @api <> "/git/blobs", %{"content" => contents}}

    assert contents =~
             "Aiur.Claude.Repl.ReaperTest\tstop_session/1 reports cleanup unknown while the process group remains alive\t#4786\t"

    assert_received {:request, :post, @api <> "/git/trees", %{"tree" => [%{"path" => "src/test/quarantine.txt"}]}}

    assert_received {:request, :post, @api <> "/pulls", body}
    assert body["base"] == "main"
    assert body["body"] =~ "Refs #4786"
    refute body["body"] =~ "Closes #4786"
    assert body["body"] =~ Enum.at(observations, 0).run_url
    assert body["body"] =~ Enum.at(observations, 1).run_url
    assert body["body"] =~ "Base-commit paths checked"
    assert body["body"] =~ "`src/lib/aiur/one.ex`"
    assert body["body"] =~ "`src/lib/aiur/two.ex`"

    # ci gate requires the pr body check, so the generated body must pass it at the commit it opened.
    template = File.read!(Path.expand("../../../../.github/pull_request_template.md", __DIR__))
    assert Aiur.PrBodyLint.errors(template, body["body"], head: @commit) == []

    assert_received {:request, :post, "https://api.github.com/graphql", %{"query" => query, "variables" => %{"id" => "PR_node_901"}}}

    assert query =~ "enablePullRequestAutoMerge"
  end

  test "does not create another PR for a test already in the quarantine list under any ticket" do
    list = "Aiur.ExampleTest\tfails repeatedly\t#800\n"

    assert {:ok, :already_quarantined} =
             QuarantinePR.open(
               %{identity: "Aiur.ExampleTest :: fails repeatedly", observations: []},
               900,
               request_fun: fn _ ->
                 flunk("already listed test must not make a GitHub request")
               end,
               token: "test-gh-token",
               quarantine_list_fun: fn -> {:ok, list} end
             )
  end

  test "a retry after a partial attempt moves the existing branch and reuses the open PR" do
    parent = self()

    retry = fn
      :get, @api <> "/git/ref/heads/aiur/quarantine/" <> _branch ->
        {:ok, %{status: 200, body: %{"object" => %{"sha" => "stale-head"}}}}

      :get, @api <> "/contents/src/test/quarantine.txt?ref=aiur/quarantine/" <> _ ->
        {:ok,
         %{
           status: 200,
           body: %{"encoding" => "base64", "content" => Base.encode64("# Existing entries\n")}
         }}

      :post, @api <> "/git/refs" ->
        {:ok, %{status: 422, body: %{"message" => "Reference already exists"}}}

      :patch, @api <> "/git/refs/heads/" <> _branch ->
        {:ok, %{status: 200, body: %{}}}

      :post, @api <> "/pulls" ->
        {:ok, %{status: 422, body: %{"message" => "A pull request already exists"}}}

      :get, @api <> "/pulls?" <> _query ->
        {:ok, %{status: 200, body: [%{"number" => 901, "node_id" => "PR_node_901"}]}}

      method, url ->
        response(method, url)
    end

    assert {:ok, %{"number" => 901}} =
             QuarantinePR.open(
               %{identity: @reaper, observations: []},
               4786,
               opts(parent, retry, fn -> {:ok, "# Existing entries\n"} end)
             )

    assert_received {:request, :patch, @api <> "/git/refs/heads/aiur/quarantine/" <> _, %{"sha" => @commit, "force" => true}}

    assert_received {:request, :post, "https://api.github.com/graphql", %{"variables" => %{"id" => "PR_node_901"}}}
  end

  test "when only auto-merge fails, the retry reuses the committed branch and writes no new head" do
    parent = self()
    {:ok, branch} = Agent.start_link(fn -> nil end)
    {:ok, graphql_calls} = Agent.start_link(fn -> 0 end)

    listed =
      "# Existing entries\nAiur.Claude.Repl.ReaperTest\tstop_session/1 reports cleanup unknown while the process group remains alive\t#4786\n"

    stateful = fn
      :get, @api <> "/git/ref/heads/aiur/quarantine/" <> _ ->
        case Agent.get(branch, & &1) do
          nil -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
          head -> {:ok, %{status: 200, body: %{"object" => %{"sha" => head}}}}
        end

      :get, @api <> "/contents/src/test/quarantine.txt?ref=aiur/quarantine/" <> _ ->
        {:ok, %{status: 200, body: %{"encoding" => "base64", "content" => Base.encode64(listed)}}}

      :post, @api <> "/git/refs" ->
        Agent.update(branch, fn _ -> @commit end)
        response(:post, @api <> "/git/refs")

      :post, @api <> "/pulls" ->
        if Agent.get(graphql_calls, & &1) == 0,
          do: response(:post, @api <> "/pulls"),
          else: {:ok, %{status: 422, body: %{"message" => "A pull request already exists"}}}

      :get, @api <> "/pulls?" <> _ ->
        {:ok, %{status: 200, body: [%{"number" => 901, "node_id" => "PR_node_901"}]}}

      :post, "https://api.github.com/graphql" ->
        if Agent.get_and_update(graphql_calls, &{&1, &1 + 1}) < 2,
          do: {:ok, %{status: 200, body: %{"errors" => [%{"message" => "Auto merge is not allowed"}]}}},
          else: response(:post, "https://api.github.com/graphql")

      method, url ->
        response(method, url)
    end

    candidate = %{identity: @reaper, observations: []}
    options = opts(parent, stateful, fn -> {:ok, "# Existing entries\n"} end)
    assert {:error, _} = QuarantinePR.open(candidate, 4786, options)
    assert {:error, _} = QuarantinePR.open(candidate, 4786, options)
    assert {:ok, %{"number" => 901}} = QuarantinePR.open(candidate, 4786, options)

    assert_received {:request, :post, @api <> "/git/commits", _}
    refute_received {:request, :post, @api <> "/git/commits", _}
    refute_received {:request, :patch, _, _}
  end

  test "a Playwright spec goes to the browser quarantine list, created on first use" do
    parent = self()

    browser = fn
      :get, @api <> "/contents/src/browser/quarantine.txt?ref=main" ->
        {:ok, %{status: 404, body: %{"message" => "Not Found"}}}

      method, url ->
        response(method, url)
    end

    # The identity the shared Playwright failure reporter annotates (#5153).
    identity = "BrowserSpec :: src/browser/tests/build-home-list.browser.spec.mjs"

    assert {:ok, %{"number" => 901}} =
             QuarantinePR.open(
               %{identity: identity, observations: []},
               5118,
               opts(parent, browser, nil)
             )

    assert_received {:request, :post, @api <> "/git/blobs", %{"content" => contents}}
    assert contents =~ ~r/\A# BrowserSpec/
    assert contents =~ "BrowserSpec\tsrc/browser/tests/build-home-list.browser.spec.mjs\t#5118\n"

    assert_received {:request, :post, @api <> "/git/trees", %{"tree" => [%{"path" => "src/browser/quarantine.txt"}]}}

    # The entry skips the whole spec file, so the body must name the file rather than "the test".
    assert_received {:request, :post, @api <> "/pulls", %{"body" => pr_body}}

    assert pr_body =~
             "Skip the flaky spec file `src/browser/tests/build-home-list.browser.spec.mjs`"

    assert pr_body =~
             "blocking CI skips every test in `src/browser/tests/build-home-list.browser.spec.mjs`"

    refute pr_body =~ "skips the test"
  end

  test "decodes GitHub content with line-wrapped base64" do
    parent = self()
    contents = "# " <> String.duplicate("quarantine list content ", 5) <> "\n"
    encoded = Base.encode64(contents)
    <<first::binary-size(60), rest::binary>> = encoded
    wrapped = first <> "\n" <> rest

    listed = fn
      :get, @api <> "/contents/src/test/quarantine.txt?ref=main" ->
        {:ok, %{status: 200, body: %{"encoding" => "base64", "content" => wrapped}}}

      method, url ->
        response(method, url)
    end

    assert {:ok, %{"number" => 901}} =
             QuarantinePR.open(
               %{identity: "Aiur.ExampleTest :: fails repeatedly", observations: []},
               900,
               opts(parent, listed, nil)
             )

    assert_received {:request, :post, @api <> "/git/blobs", %{"content" => updated}}

    assert updated ==
             String.trim_trailing(contents) <>
               "\nAiur.ExampleTest\tfails repeatedly\t#900\t" <>
               Date.to_iso8601(Date.add(Date.utc_today(), 90)) <> "\n"
  end

  defp opts(parent, responder, list_fun) do
    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})
      responder.(method, url)
    end

    base = [request_fun: request, token: "test-gh-token", base_branch: "main"]
    if list_fun, do: Keyword.put(base, :quarantine_list_fun, list_fun), else: base
  end

  defp response(:get, @api <> "/git/ref/heads/aiur/quarantine/" <> _),
    do: {:ok, %{status: 404, body: %{"message" => "Not Found"}}}

  defp response(:get, @api <> "/git/ref/heads/main"),
    do: {:ok, %{status: 200, body: %{"object" => %{"sha" => @base}}}}

  defp response(:get, @api <> "/git/commits/" <> @base),
    do: {:ok, %{status: 200, body: %{"tree" => %{"sha" => "base-tree"}}}}

  defp response(:post, @api <> "/git/blobs"),
    do: {:ok, %{status: 201, body: %{"sha" => "new-blob"}}}

  defp response(:post, @api <> "/git/trees"),
    do: {:ok, %{status: 201, body: %{"sha" => "new-tree"}}}

  defp response(:post, @api <> "/git/commits"),
    do: {:ok, %{status: 201, body: %{"sha" => @commit}}}

  defp response(:post, @api <> "/git/refs"),
    do: {:ok, %{status: 201, body: %{"object" => %{"sha" => @commit}}}}

  defp response(:post, @api <> "/pulls"),
    do: {:ok, %{status: 201, body: %{"number" => 901, "node_id" => "PR_node_901"}}}

  defp response(:post, "https://api.github.com/graphql"),
    do:
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{"enablePullRequestAutoMerge" => %{"pullRequest" => %{"number" => 901}}}
         }
       }}

  defp response(method, url), do: flunk("unexpected GitHub request #{method} #{url}")
end
