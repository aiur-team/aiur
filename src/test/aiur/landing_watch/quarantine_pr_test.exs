defmodule Aiur.LandingWatch.QuarantinePRTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.QuarantinePR

  @api "https://api.github.com/repos/test-org/test-repo"
  @commit String.duplicate("c", 40)
  @base String.duplicate("b", 40)
  @reaper_name "stop_session/1 reports cleanup unknown while the process group remains alive"
  @reaper "Aiur.Claude.Repl.ReaperTest :: " <> @reaper_name

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
               quarantine_list_fun: fn -> {:ok, list} end,
               tests_root: tests_root()
             )
  end

  test "browser quarantine entry names one title and source line" do
    identity = "BrowserSpec :: src/browser/tests/streamdeck-emulator-modes-paging.browser.spec.mjs :: an active dial drag commits its final value after a LiveView patch :: 187"
    assert {:ok, contents} = QuarantinePR.entry(identity, 7020, "# Browser quarantine\n", nil)
    assert contents =~ "BrowserSpec\tsrc/browser/tests/streamdeck-emulator-modes-paging.browser.spec.mjs\tan active dial drag commits its final value after a LiveView patch\t187\t#7020"
    refute contents =~ "\t#7020\nBrowserSpec\tsrc/browser/tests/streamdeck-emulator-modes-paging.browser.spec.mjs\t#7020"
  end

  test "inserts an ExUnit row in sorted position and quarantines suite-wide ambiguous names by module" do
    root = Aiur.TestSupport.tmp_root!("quarantine-suite")
    tests_root = Path.join(root, "test")
    File.mkdir_p!(tests_root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    File.write!(
      Path.join(tests_root, "a_test.exs"),
      "defmodule Aiur.ATest do\n  test \"alpha\", do: :ok\nend\n"
    )

    File.write!(
      Path.join(tests_root, "m_test.exs"),
      "defmodule Aiur.MTest do\n  describe \"group\" do\n    test \"shared name\", do: :ok\n    test \"middle\", do: :ok\n  end\n  defmodule ChildTest do\n    describe \"group\" do\n      test \"shared name\", do: :ok\n    end\n  end\nend\n"
    )

    File.write!(
      Path.join(tests_root, "z_test.exs"),
      "defmodule Aiur.ZTest do\n  test \"omega\", do: :ok\nend\n"
    )

    expiry = Date.add(Date.utc_today(), 2)
    contents = "# Existing entries\nAiur.ATest\talpha\t#1\t#{expiry}\nAiur.ZTest\tomega\t#2\t#{expiry}\n"

    assert {:ok, sorted} =
             QuarantinePR.entry("Aiur.MTest :: group middle", 7021, contents, expiry, tests_root)

    assert {:ok, entries} = Aiur.TestQuarantine.parse(sorted)

    assert Enum.map(entries, &Aiur.TestQuarantine.sort_key/1) ==
             [{"Aiur.ATest", "alpha"}, {"Aiur.MTest", "group middle"}, {"Aiur.ZTest", "omega"}]

    assert {:ok, ambiguous} =
             QuarantinePR.entry("Aiur.MTest :: group shared name", 7022, contents, expiry, tests_root)

    assert ambiguous =~ "Aiur.MTest\t*\t#7022\t#{expiry}\n"
    assert {:ok, ambiguous_entries} = Aiur.TestQuarantine.parse(ambiguous)
    assert Enum.any?(ambiguous_entries, &(&1.module == "Aiur.MTest" and &1.name == "*"))

    python = """
    import importlib.util, pathlib, sys
    from datetime import date
    sys.dont_write_bytecode = True
    script_path, list_path, tests_path, today_text, expiry_text = sys.argv[1:]
    spec = importlib.util.spec_from_file_location("run_quarantined_tests", script_path)
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    listed = validator.entries(pathlib.Path(list_path), grandfathered=frozenset(), today=date.fromisoformat(today_text))
    selected = validator.selectors(pathlib.Path(tests_path), listed=listed)
    assert ("Aiur.MTest", "*", "#7022", expiry_text) in listed
    assert selected == ["test/a_test.exs:2", "test/m_test.exs:3", "test/m_test.exs:4", "test/z_test.exs:2"]
    """

    list_path = Path.join(root, "quarantine.txt")
    File.write!(list_path, ambiguous)
    validator_path = Path.expand("../../../../scripts/run-quarantined-tests.py", __DIR__)

    assert {output, 0} =
             System.cmd(
               "python3",
               [
                 "-c",
                 python,
                 validator_path,
                 list_path,
                 tests_root,
                 Date.to_iso8601(Date.utc_today()),
                 Date.to_iso8601(Date.add(Date.utc_today(), 2))
               ],
               stderr_to_stdout: true,
               cd: root
             )

    assert output == ""
  end

  test "an existing module-wide ExUnit quarantine row makes retries idempotent" do
    expiry = Date.add(Date.utc_today(), 2)
    contents = "Aiur.MTest\t*\t#2\t#{expiry}\n"

    assert {:error, :already_quarantined} =
             QuarantinePR.entry("Aiur.MTest :: shared name", 7023, contents, expiry, tests_root())
  end

  test "same per-test row is already listed and legacy whole-spec row covers it" do
    identity = "BrowserSpec :: src/browser/tests/example.browser.spec.mjs :: skips one test :: 187"
    per_test = "BrowserSpec\tsrc/browser/tests/example.browser.spec.mjs\tskips one test\t187\t#7020\n"
    whole_spec = "BrowserSpec\tsrc/browser/tests/example.browser.spec.mjs\t#7027\n"

    assert {:error, :already_quarantined} = QuarantinePR.entry(identity, 7020, per_test, nil)
    assert {:error, :already_quarantined} = QuarantinePR.entry(identity, 7020, whole_spec, nil)
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

  test "open/3 checks name uniqueness in the injected tests root, not the real suite" do
    parent = self()
    root = tests_root()
    File.write!(Path.join(root, "other_test.exs"), "defmodule Aiur.OtherTest do\n  test \"#{@reaper_name}\", do: :ok\nend\n")

    assert {:ok, %{"number" => 901}} =
             QuarantinePR.open(
               %{identity: @reaper, observations: []},
               4786,
               Keyword.put(opts(parent, &response/2, fn -> {:ok, "# Existing entries\n"} end), :tests_root, root)
             )

    assert_received {:request, :post, @api <> "/git/blobs", %{"content" => contents}}
    assert contents =~ "Aiur.Claude.Repl.ReaperTest\t*\t#4786\t"
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
               %{identity: @reaper, observations: []},
               900,
               Keyword.put(opts(parent, listed, nil), :quarantine_expires_on, Date.add(Date.utc_today(), 90))
             )

    assert_received {:request, :post, @api <> "/git/blobs", %{"content" => updated}}

    assert updated ==
             contents <>
               "Aiur.Claude.Repl.ReaperTest\tstop_session/1 reports cleanup unknown while the process group remains alive\t#900\t" <>
               Date.to_iso8601(Date.add(Date.utc_today(), 14)) <> "\n"
  end

  defp opts(parent, responder, list_fun) do
    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})
      responder.(method, url)
    end

    base = [request_fun: request, token: "test-gh-token", base_branch: "main", tests_root: tests_root()]
    if list_fun, do: Keyword.put(base, :quarantine_list_fun, list_fun), else: base
  end

  # A one-file suite: without it each open/3 scans every real *_test.exs for name uniqueness (#7383).
  defp tests_root do
    root = Path.join(Aiur.TestSupport.tmp_root!("quarantine-pr-tests"), "test")
    File.mkdir_p!(root)

    # One-line source: a heredoc here would itself match the real-suite scanner's defmodule/test patterns.
    File.write!(Path.join(root, "reaper_test.exs"), "defmodule Aiur.Claude.Repl.ReaperTest do\n  test \"#{@reaper_name}\", do: :ok\nend\n")

    root
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
