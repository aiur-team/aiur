defmodule Aiur.LandingWatch.QuarantineLifterTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{QuarantineLifter, QuarantineNightlyResults}

  test "the reported quarantine and lift PRs do not trigger another lift" do
    expiry = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

    cases = [
      {6584, 6328, "Aiur.ExampleTest\tfixed flakes\t#6328\t#{expiry}\n"},
      {6577, 6571, "Aiur.ExampleTest\tfixed flakes\t#6571\t#{expiry}\n"},
      {7118, 7090, "Aiur.ExampleTest\tfixed flakes\t#7090\t#{expiry}\n"},
      {7122, 7090, "Aiur.ExampleTest\tfixed flakes\t#7090\t#{expiry}\n"}
    ]

    for {pr_number, ticket, quarantine} <- cases do
      journal = Path.join(System.tmp_dir!(), "quarantine-lifter-regression-#{pr_number}-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
      parent = self()

      request = fn %{method: method, url: url} = call ->
        send(parent, {:request, method, url, Map.get(call, :body)})

        if url == "https://api.github.com/repos/test-org/test-repo/pulls/#{pr_number}/files?per_page=100" do
          {:ok, %{status: 200, body: [%{"filename" => "src/test/quarantine.txt", "patch" => "@@ -1 +1 @@\n-row\n+row"}]}}
        else
          response(method, url, quarantine)
        end
      end

      assert :ok =
               QuarantineLifter.lift_after_merge(ticket, %{"number" => pr_number, "body" => "Refs ##{ticket}"},
                 request_fun: request,
                 token: "test-gh-token",
                 repository: "test-org/test-repo",
                 base_branch: "main",
                 journal_path: journal
               )

      refute_received {:request, :put, _, _}
      refute_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", _}
    end
  end

  test "a test.skip-only change does not count as a fix" do
    expiry = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-skip-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    parent = self()

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})

      if url == "https://api.github.com/repos/test-org/test-repo/pulls/8003/files?per_page=100" do
        {:ok, %{status: 200, body: [%{"filename" => "src/test/aiur/example_test.exs", "patch" => "@@ -1 +1 @@\n-test(\\\"flaky\\\", fn ->\n+test.skip(\\\"flaky\\\", fn ->"}]}}
      else
        response(method, url, "Aiur.ExampleTest\tflaky\t#900\t#{expiry}\n")
      end
    end

    assert :ok =
             QuarantineLifter.lift_after_merge(900, %{"number" => 8003, "body" => "Refs #900"},
               request_fun: request,
               token: "test-gh-token",
               repository: "test-org/test-repo",
               base_branch: "main",
               journal_path: journal
             )

    refute_received {:request, :put, _, _}
    refute_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", _}
  end

  test "an unavailable PR file list fails closed without opening a lift PR" do
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-files-error-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)

    request = fn %{url: url} ->
      if url == "https://api.github.com/repos/test-org/test-repo/pulls/8004/files?per_page=100",
        do: {:ok, %{status: 503, body: %{"message" => "temporary unavailable"}}},
        else: flunk("unexpected GitHub request #{url}")
    end

    assert {:error, _reason} =
             QuarantineLifter.lift_after_merge(900, %{"number" => 8004, "body" => "Refs #900"},
               request_fun: request,
               token: "test-gh-token",
               repository: "test-org/test-repo",
               base_branch: "main",
               journal_path: journal
             )
  end

  test "a merged fix PR that closes its ticket opens the quarantine lift PR" do
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-real-fix-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    expiry = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()
    original = "# Quarantine list\nAiur.ExampleTest\tfixed flakes\t#900\t#{expiry}\nAiur.OtherTest\tstill flaky\t#901\t#{expiry}\n"
    parent = self()

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})

      if url == "https://api.github.com/repos/test-org/test-repo/pulls/9001/files?per_page=100" do
        {:ok, %{status: 200, body: [%{"filename" => "src/lib/aiur/decision_store.ex", "patch" => "@@ -1 +1 @@\n-old\n+fixed"}]}}
      else
        if url == "https://api.github.com/repos/test-org/test-repo/issues/900",
          do: {:ok, %{status: 200, body: %{"state" => "closed"}}},
          else: response(method, url, original)
      end
    end

    assert :ok =
             QuarantineLifter.lift_after_merge(900, %{"number" => 9001, "body" => "Closes #900"},
               request_fun: request,
               token: "test-gh-token",
               repository: "test-org/test-repo",
               base_branch: "main",
               journal_path: journal
             )

    assert_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", body}
    {:ok, content} = Base.decode64(body["content"])
    refute content =~ "#900"
    assert content =~ "#901"
    assert_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", pr}
    assert pr["body"] =~ "#900"
  end

  test "a merged fix ticket opens a PR removing its quarantine row" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    original = "# Quarantine list\nAiur.ExampleTest\tfixed flakes\t#900\nAiur.OtherTest\tstill flaky\t#901\n"

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})
      response(method, url, original)
    end

    assert :ok =
             QuarantineLifter.lift(900,
               request_fun: request,
               token: "test-gh-token",
               base_branch: "main",
               journal_path: journal
             )

    assert_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", body}
    {:ok, content} = Base.decode64(body["content"])
    refute content =~ "#900"
    assert content =~ "#901"
    assert body["branch"] == "aiur/quarantine-lift-900-main"

    assert_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", pr}
    assert pr["base"] == "main"
    assert pr["body"] =~ "#900"
  end

  test "a merged fix ticket also lifts its quarantined browser spec" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-browser-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    browser = "# Spec list\nBrowserSpec\tsrc/browser/tests/build-home-list.browser.spec.mjs\t#5118\n"

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})
      browser_response(method, url, browser)
    end

    assert :ok = QuarantineLifter.lift(5118, request_fun: request, token: "test-gh-token", base_branch: "main", journal_path: journal)

    assert_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt", body}
    {:ok, content} = Base.decode64(body["content"])
    refute content =~ "build-home-list"
    assert body["branch"] == "aiur/quarantine-lift-5118-main-browser"
    refute_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", _}
  end

  test "a merged fix ticket lifts a per-test browser row and list_tickets reads its ticket" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-per-test-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    browser = "# Spec list\nBrowserSpec\tsrc/browser/tests/build-home-list.browser.spec.mjs\tone test fails\t187\t#5119\n"

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})

      case url do
        "https://api.github.com/repos/test-org/test-repo/issues/5119" ->
          {:ok, %{status: 200, body: %{"state" => "closed"}}}

        "https://api.github.com/repos/test-org/test-repo/issues/5119/timeline?per_page=100" ->
          {:ok, %{status: 200, body: [%{"event" => "cross-referenced", "source" => %{"issue" => %{"number" => 9120, "body" => "Closes #5119", "pull_request" => %{}}}}]}}

        "https://api.github.com/repos/test-org/test-repo/pulls/9120/files?per_page=100" ->
          {:ok, %{status: 200, body: [%{"filename" => "src/browser/tests/build-home-list.browser.spec.mjs", "patch" => "@@ -1 +1 @@\n-old\n+fixed"}]}}

        "https://api.github.com/repos/test-org/test-repo/pulls/9120" ->
          {:ok, %{status: 200, body: %{"merged_at" => "2026-10-29T00:00:00Z"}}}

        _ ->
          browser_response(method, url, browser)
      end
    end

    assert :ok =
             QuarantineLifter.lift_closed(
               request_fun: request,
               token: "test-gh-token",
               base_branch: "main",
               journal_path: journal,
               nightly_quarantine_results_fun: fn _ -> {:ok, []} end
             )

    assert_received {:request, :get, "https://api.github.com/repos/test-org/test-repo/issues/5119", _}
    assert_received {:request, :put, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt", body}
    {:ok, content} = Base.decode64(body["content"])
    refute content =~ "one test fails"
  end

  test "a closed ticket with only a quarantine PR reference keeps its entry" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "quarantine-lifter-closed-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    original = "# Quarantine list\nAiur.ExampleTest\tabandoned flake\t#900\nAiur.OtherTest\tstill flaky\t#901\n"

    request = fn %{method: method, url: url} = call ->
      send(parent, {:request, method, url, Map.get(call, :body)})

      case url do
        "https://api.github.com/repos/test-org/test-repo/issues/900" ->
          {:ok, %{status: 200, body: %{"state" => "closed"}}}

        "https://api.github.com/repos/test-org/test-repo/issues/901" ->
          {:ok, %{status: 200, body: %{"state" => "open"}}}

        "https://api.github.com/repos/test-org/test-repo/issues/900/timeline?per_page=100" ->
          {:ok, %{status: 200, body: [%{"event" => "cross-referenced", "source" => %{"issue" => %{"number" => 8123, "body" => "Closes #900", "pull_request" => %{}}}}]}}

        "https://api.github.com/repos/test-org/test-repo/pulls/8123/files?per_page=100" ->
          {:ok, %{status: 200, body: [%{"filename" => "src/test/quarantine.txt", "patch" => "@@ -1 +1 @@\n+Aiur.ExampleTest\tflaky\t#900"}]}}

        "https://api.github.com/repos/test-org/test-repo/pulls/8123" ->
          {:ok, %{status: 200, body: %{"merged_at" => "2026-10-29T00:00:00Z"}}}

        _ ->
          response(method, url, original)
      end
    end

    assert :ok =
             QuarantineLifter.lift_closed(
               request_fun: request,
               token: "test-gh-token",
               base_branch: "main",
               journal_path: journal,
               nightly_quarantine_results_fun: fn _ -> {:ok, []} end
             )

    assert_received {:request, :get, "https://api.github.com/repos/test-org/test-repo/issues/900/timeline?per_page=100", _}
    refute_received {:request, :put, _, _}
    refute_received {:request, :post, "https://api.github.com/repos/test-org/test-repo/pulls", _}
  end

  test "expired quarantine lifts after three green nightly runs" do
    parent = self()

    assert :ok =
             QuarantineLifter.lift_expired(
               test_quarantine_contents_fun: fn _ -> {:ok, "Aiur.ExampleTest\tgreen again\t#900\t2026-10-20\n"} end,
               today: ~D[2026-10-21],
               nightly_quarantine_results_fun: fn _ ->
                 {:ok, List.duplicate(%{fallback: :success, failures: %{}}, 3)}
               end,
               quarantine_lift_fun: fn ticket, opts ->
                 send(parent, {:lift, ticket, opts[:lift_reason]})
                 :ok
               end
             )

    assert_received {:lift, 900, "after 3 green nightly quarantine runs"}
  end

  test "expired quarantine escalates only the test whose nightly annotations still fail" do
    journal = Path.join(System.tmp_dir!(), "quarantine-failing-journal-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    parent = self()

    request = fn %{method: method, url: url} = call ->
      send(parent, {:label, method, url, Map.get(call, :body)})
      status = if method == :delete, do: 404, else: 200
      {:ok, %{status: status, body: []}}
    end

    assert :ok =
             QuarantineLifter.lift_expired(
               test_quarantine_contents_fun: fn _ ->
                 {:ok, "Aiur.ExampleTest\tstill failing\t#900\t2026-10-20\nAiur.OtherTest\tgreen\t#901\t2026-10-20\n"}
               end,
               today: ~D[2026-10-21],
               token: "test-gh-token",
               journal_path: journal,
               request_fun: request,
               nightly_quarantine_results_fun: fn _ ->
                 {:ok, [%{fallback: :success, failures: %{"Aiur.ExampleTest :: still failing" => :failure}}]}
               end
             )

    assert_received {:label, :post, "https://api.github.com/repos/test-org/test-repo/issues/900/labels", %{"labels" => ["priority:1"]}}
    assert_received {:label, :delete, "https://api.github.com/repos/test-org/test-repo/issues/900/labels/priority:2", nil}
    refute_received {:label, :post, "https://api.github.com/repos/test-org/test-repo/issues/901/labels", _}
  end

  test "an unexpired quarantine entry does not query nightly results or lift" do
    parent = self()

    assert :ok =
             QuarantineLifter.lift_expired(
               test_quarantine_contents_fun: fn _ -> {:ok, "Aiur.ExampleTest\tstill waiting\t#900\t2026-12-31\n"} end,
               today: ~D[2026-10-21],
               nightly_quarantine_results_fun: fn _ ->
                 send(parent, :nightly_results_requested)
                 {:ok, []}
               end,
               quarantine_lift_fun: fn ticket, _opts ->
                 send(parent, {:lift, ticket})
                 :ok
               end
             )

    refute_received :nightly_results_requested
    refute_received {:lift, _}
  end

  test "expired entries are read from the configured base branch contents API" do
    parent = self()
    contents = "Aiur.ExampleTest\twaiting\t#900\t2026-10-20\n"

    request = fn %{url: url} ->
      send(parent, {:contents_read, url})
      {:ok, %{status: 200, body: %{"content" => Base.encode64(contents), "sha" => "list-sha", "encoding" => "base64"}}}
    end

    assert :ok =
             QuarantineLifter.lift_expired(
               base_branch: "release",
               token: "test-gh-token",
               request_fun: request,
               today: ~D[2026-10-21],
               nightly_quarantine_results_fun: fn _ -> {:ok, []} end
             )

    assert_received {:contents_read, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt?ref=release"}
  end

  test "two green runs and one failing run do not lift an expired entry" do
    journal = Path.join(System.tmp_dir!(), "quarantine-two-green-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    parent = self()

    request = fn %{method: method, url: url} = call ->
      send(parent, {:label, method, url, Map.get(call, :body)})
      {:ok, %{status: 200, body: []}}
    end

    failure = %{fallback: :success, failures: %{"Aiur.ExampleTest :: still failing" => :failure}}
    green = %{fallback: :success, failures: %{}}

    assert :ok =
             QuarantineLifter.lift_expired(
               test_quarantine_contents_fun: fn _ -> {:ok, "Aiur.ExampleTest\tstill failing\t#900\t2026-10-20\n"} end,
               today: ~D[2026-10-21],
               token: "test-gh-token",
               journal_path: journal,
               request_fun: request,
               nightly_quarantine_results_fun: fn _ -> {:ok, [green, green, failure]} end,
               quarantine_lift_fun: fn ticket, _opts ->
                 send(parent, {:lift, ticket})
                 :ok
               end
             )

    assert_received {:label, :post, "https://api.github.com/repos/test-org/test-repo/issues/900/labels", %{"labels" => ["priority:1"]}}
    refute_received {:lift, 900}
  end

  test "nightly quarantine results treat a failed step conclusion as failure" do
    request = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/actions/runs?event=schedule&status=completed&per_page=20") ->
          {:ok, %{status: 200, body: %{"workflow_runs" => [%{"name" => "ci", "head_branch" => "main", "id" => 7}]}}}

        String.ends_with?(url, "/actions/runs/7/jobs?per_page=100") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "jobs" => [
                 %{
                   "name" => "quarantined tests (non-blocking)",
                   "check_run_id" => 7,
                   "conclusion" => "success",
                   "steps" => [%{"name" => "Run quarantined tests", "conclusion" => "failure"}]
                 }
               ]
             }
           }}

        true ->
          flunk("unexpected request #{url}")
      end
    end

    assert {:ok, [%{run_id: 7, fallback: :success, failures: %{"Aiur.ExampleTest :: exact failure" => :failure}}]} =
             QuarantineNightlyResults.fetch(
               base_branch: "main",
               token: "test-gh-token",
               request_fun: request,
               annotations_fun: fn 7, _ ->
                 {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: Aiur.ExampleTest :: exact failure"}]}
               end
             )
  end

  defp response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt?ref=main", contents),
    do: {:ok, %{status: 200, body: %{"content" => Base.encode64(contents), "sha" => "list-blob", "encoding" => "base64"}}}

  # The browser list does not exist until a spec is first quarantined.
  defp response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt?ref=main", _contents),
    do: {:ok, %{status: 404, body: %{"message" => "Not Found"}}}

  defp response(:get, "https://api.github.com/repos/test-org/test-repo/git/ref/heads/main", _contents),
    do: {:ok, %{status: 200, body: %{"object" => %{"sha" => "base-commit"}}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/git/refs", _contents),
    do: {:ok, %{status: 201, body: %{}}}

  defp response(:put, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt", _contents),
    do: {:ok, %{status: 200, body: %{}}}

  defp response(:post, "https://api.github.com/repos/test-org/test-repo/pulls", _contents),
    do: {:ok, %{status: 201, body: %{}}}

  defp response(method, url, _contents), do: flunk("unexpected GitHub request #{method} #{url}")

  defp browser_response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt?ref=main", contents),
    do: {:ok, %{status: 200, body: %{"content" => Base.encode64(contents), "sha" => "browser-blob", "encoding" => "base64"}}}

  defp browser_response(:get, "https://api.github.com/repos/test-org/test-repo/contents/src/test/quarantine.txt?ref=main", _contents),
    do: {:ok, %{status: 200, body: %{"content" => Base.encode64("# Quarantine list\n"), "sha" => "list-blob", "encoding" => "base64"}}}

  defp browser_response(:put, "https://api.github.com/repos/test-org/test-repo/contents/src/browser/quarantine.txt", _contents),
    do: {:ok, %{status: 200, body: %{}}}

  defp browser_response(method, url, contents), do: response(method, url, contents)
end
