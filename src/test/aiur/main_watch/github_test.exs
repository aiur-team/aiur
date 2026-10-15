defmodule Aiur.MainWatch.GitHubTest do
  use Aiur.TestSupport
  alias Aiur.MainWatch.{GitHub, State}

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "chronological watched observations exclude website failures, pending and cancelled commits" do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") ->
          ok(Enum.map(~w(new pending cancelled old), &%{"sha" => &1}))

        String.contains?(url, "/actions/runs?") ->
          runs = [
            run(4, "new", "ci", "completed", "success"),
            run(3, "pending", "ci", "in_progress", nil),
            run(2, "cancelled", "ci", "completed", "cancelled"),
            run(1, "old", "ci", "completed", "success")
          ]

          ok(%{"workflow_runs" => runs ++ Enum.map(runs, &Map.merge(&1, %{"id" => &1["id"] + 10, "name" => "website", "conclusion" => "failure"}))})

        String.contains?(url, "/check-runs?") ->
          ok(%{"check_runs" => [check(1, 1, "success"), check(2, 2, "failure")]})

        String.ends_with?(url, "/status") ->
          ok(%{"statuses" => [%{"state" => "error", "context" => "external"}]})

        true ->
          flunk("unexpected request #{url}")
      end
    end

    assert {:ok, result} = GitHub.poll("main", ["ci"], request_fun: request, actions_write: false)
    assert Enum.map(result.observations, & &1.sha) == ["old", "new"]
    assert Enum.map(result.runs, & &1.sha) == ["new", "pending", "cancelled", "old"]
    assert Enum.map(result.observations, & &1.checks) == List.duplicate([%{name: "test", conclusion: "success"}], 2)
    assert Enum.all?(result.observations, &(&1.digest.checks == []))
    assert hd(result.observations).completed_at == DateTime.to_unix(~U[2026-10-10 00:00:00Z], :millisecond)
  end

  test "refreshes a rejected App installation token once and retries the poll" do
    attempts = :atomics.new(1, [])
    refreshes = :atomics.new(1, [])

    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") and :atomics.add_get(attempts, 1, 1) == 1 ->
          {:ok, %{status: 401, body: %{"message" => "Bad credentials"}}}

        String.contains?(url, "/commits?") ->
          ok([])

        String.contains?(url, "/actions/runs?") ->
          ok(%{"workflow_runs" => []})

        true ->
          flunk("unexpected request #{url}")
      end
    end

    assert {:ok, %{commits: []}} =
             GitHub.poll("main", [],
               request_fun: request,
               actions_write: false,
               credential_source: fn -> :github_app end,
               refresh_app_token_fun: fn ->
                 :atomics.add_get(refreshes, 1, 1)
                 :ok
               end
             )

    assert :atomics.get(attempts, 1) == 2
    assert :atomics.get(refreshes, 1) == 1
  end

  test "reports the failing caller and credential class on an unrecoverable 401" do
    request = fn _request -> {:ok, %{status: 401, body: %{"message" => "Bad credentials"}}} end

    assert {:error, {:github, :auth, %{status: 401, caller: "main_watch_commits", credential: "github_app_installation"}}} =
             GitHub.poll("main", [],
               request_fun: request,
               credential_source: fn -> :github_app end,
               refresh_app_token_fun: fn -> {:error, :refresh_failed} end
             )
  end

  test "missing configured workflows stay pending while older complete SHA remains observable" do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") ->
          ok([%{"sha" => "new"}, %{"sha" => "old"}])

        String.contains?(url, "/actions/runs?") ->
          ok(%{"workflow_runs" => [run(1, "new", "ci", "completed", "success"), run(1, "old", "ci", "completed", "success"), run(2, "old", "deploy", "completed", "success")]})

        String.contains?(url, "/check-runs?") ->
          ok(%{"check_runs" => [check(1, 1, "success"), check(2, 2, "success")]})

        String.ends_with?(url, "/status") ->
          ok(%{"statuses" => []})

        true ->
          flunk("unexpected request #{url}")
      end
    end

    assert {:ok, result} = GitHub.poll("main", ["ci", "deploy"], request_fun: request, actions_write: false)
    assert Enum.map(result.observations, & &1.sha) == ["old"]
  end

  test "watched failure retains annotations while website failures stay excluded" do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") -> ok([%{"sha" => "red-filtered"}])
        String.contains?(url, "/actions/runs?") -> ok(%{"workflow_runs" => [run(1, "red-filtered", "ci", "completed", "failure"), run(2, "red-filtered", "website", "completed", "failure")]})
        String.contains?(url, "/commits/red-filtered/check-runs?") -> ok(%{"check_runs" => [check(1, 1, "failure"), check(2, 2, "failure")]})
        String.ends_with?(url, "/status") -> ok(%{"statuses" => []})
        String.contains?(url, "/check-runs/1/annotations?") -> ok([%{"title" => "aiur-test-failure", "message" => "new-failure :: ExampleTest :: regression", "annotation_level" => "failure"}])
        String.contains?(url, "/contents/") -> ok(%{"encoding" => "base64", "content" => ""})
        String.contains?(url, "/issues?") -> ok([])
        true -> flunk("unwatched annotations must not be read: #{url}")
      end
    end

    assert {:ok, %{observations: [observation]}} = GitHub.poll("main", ["ci"], request_fun: request, actions_write: false)
    assert [%{id: 1, name: "test", tests: [%{identity: "ExampleTest :: regression", classification: :new_failure, path: nil}]}] = observation.digest.checks
    assert observation.digest.tests == [%{identity: "ExampleTest :: regression", classification: :new_failure, path: nil}]
    refute observation.digest.flake_only
  end

  test "fail-fast cancelled children remain real failure evidence for completed failed workflow" do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") -> ok([%{"sha" => "fail-fast-red"}])
        String.contains?(url, "/actions/runs?") -> ok(%{"workflow_runs" => [run(1, "fail-fast-red", "ci", "completed", "failure")]})
        String.contains?(url, "/check-runs?") -> ok(%{"check_runs" => [check(1, 1, "failure"), Map.put(check(2, 1, "cancelled"), "name", "cancelled partition")]})
        String.ends_with?(url, "/status") -> ok(%{"statuses" => []})
        String.contains?(url, "/check-runs/1/annotations?") -> ok([%{"title" => "aiur-test-failure", "message" => "new-failure :: ExampleTest :: fail fast", "annotation_level" => "failure"}])
        String.contains?(url, "/check-runs/2/annotations?") -> ok([])
        String.contains?(url, "/contents/") -> ok(%{"encoding" => "base64", "content" => ""})
        String.contains?(url, "/issues?") -> ok([])
        true -> flunk("unexpected request: #{url}")
      end
    end

    assert {:ok, %{observations: [observation]}} = GitHub.poll("main", ["ci"], request_fun: request, actions_write: false)
    assert observation.failed_workflow
    assert Enum.sort(Enum.map(observation.checks, & &1.conclusion)) == ["cancelled", "failure"]
    assert Enum.map(observation.digest.checks, & &1.id) == [1, 2]
    assert observation.digest.tests == [%{identity: "ExampleTest :: fail fast", classification: :new_failure, path: nil}]
    refute observation.digest.flake_only
  end

  test "newest successful check attempt supersedes a cancelled older check in its suite" do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") -> ok([%{"sha" => "rerun-success"}])
        String.contains?(url, "/actions/runs?") -> ok(%{"workflow_runs" => [run(1, "rerun-success", "ci", "completed", "success")]})
        String.contains?(url, "/check-runs?") -> ok(%{"check_runs" => [check(1, 1, "cancelled"), check(2, 1, "success")]})
        String.ends_with?(url, "/status") -> ok(%{"statuses" => []})
        true -> flunk("superseded cancelled check must not buy annotations: #{url}")
      end
    end

    assert {:ok, %{observations: [observation]}} = GitHub.poll("main", ["ci"], request_fun: request, actions_write: false)
    assert observation.checks == [%{name: "test", conclusion: "success"}]
    assert observation.digest.checks == []
  end

  test "one branch census reuses completed history and refreshes a changed rerun" do
    shas = Enum.map(1..20, &"counted-#{&1}")
    runs = Enum.with_index(shas, 1) |> Enum.map(fn {sha, id} -> run(id, sha, "ci", "completed", "success") end)
    {:ok, calls} = Agent.start_link(fn -> %{runs: runs, requests: []} end)

    request = fn %{url: url} ->
      current = Agent.get_and_update(calls, fn state -> {state.runs, %{state | requests: state.requests ++ [url]}} end)

      cond do
        String.contains?(url, "/commits?") ->
          ok(Enum.map(shas, &%{"sha" => &1}))

        String.contains?(url, "/actions/runs?") ->
          query = URI.decode_query(URI.parse(url).query)
          assert query in [%{"branch" => "main", "event" => "push", "per_page" => "100"}, %{"event" => "merge_group", "per_page" => "100"}]
          ok(%{"workflow_runs" => current ++ [run(99, "outside-window", "ci", "completed", "failure")]})

        String.contains?(url, "/check-runs?") ->
          ok(%{"check_runs" => [check(1, 1, "success")]})

        String.ends_with?(url, "/status") ->
          ok(%{"statuses" => []})

        true ->
          flunk("unchanged history must not fetch evidence: #{url}")
      end
    end

    opts = [request_fun: request, actions_write: false]
    assert {:ok, cold} = GitHub.poll("main", ["ci"], opts)
    assert Enum.map(cold.observations, & &1.sha) == Enum.reverse(shas)
    assert length(Agent.get(calls, & &1.requests)) == 43
    Agent.update(calls, &%{&1 | requests: []})
    history = Enum.reduce(cold.observations, State.new(), fn observation, state -> State.record_history(state, observation, observation.completed_at) end).history
    assert {:ok, warm} = GitHub.poll("main", ["ci"], Keyword.put(opts, :history, history))
    assert warm.observations == cold.observations
    assert length(Agent.get(calls, & &1.requests)) == 3

    Agent.update(calls, fn state -> %{state | requests: [], runs: [Map.put(hd(state.runs), "run_attempt", 2) | tl(state.runs)]} end)
    assert {:ok, rerun} = GitHub.poll("main", ["ci"], Keyword.put(opts, :history, warm.observations))
    assert length(Agent.get(calls, & &1.requests)) == 5
    refute List.last(rerun.observations).run_fingerprint == List.last(warm.observations).run_fingerprint

    Agent.update(calls, &%{&1 | requests: []})
    legacy = Enum.map(rerun.observations, &Map.delete(&1, :run_fingerprint))
    assert {:ok, migrated} = GitHub.poll("main", ["ci"], Keyword.put(opts, :history, legacy))
    assert migrated.observations == rerun.observations
    assert length(Agent.get(calls, & &1.requests)) == 43
  end

  test "paginated census covers time despite merge-queue commits without push runs and default workflows" do
    commits = for day <- 20..1//-1, do: %{"sha" => "commit-#{day}", "commit" => %{"committer" => %{"date" => "2026-09-#{String.pad_leading(to_string(day), 2, "0")}T00:00:00Z"}}}
    push_commits = Enum.drop(commits, 7)

    runs =
      Enum.with_index(push_commits, 1) |> Enum.map(fn {commit, id} -> Map.put(run(id, commit["sha"], "ci", "completed", "success"), "created_at", get_in(commit, ["commit", "committer", "date"])) end)

    older = Map.put(run(100, "outside-window", "ci", "completed", "success"), "created_at", "2026-08-31T00:00:00Z")

    for workflows <- [["ci"], []] do
      assert {:ok, result} = GitHub.poll("main", workflows, request_fun: census_request(commits, runs ++ [older]), actions_write: false)
      assert result.commits == Enum.map(commits, & &1["sha"])
      assert Enum.map(result.observations, & &1.sha) == Enum.map(Enum.reverse(push_commits), & &1["sha"])
      assert length(result.runs) == 13
    end
  end

  test "paginated census rejects uncovered time even when every workflow and SHA is represented" do
    commits = [%{"sha" => "new", "commit" => %{"committer" => %{"date" => "2026-10-09T00:00:00Z"}}}]
    newer = Map.put(run(1, "new", "ci", "completed", "success"), "created_at", "2026-10-10T00:00:00Z")

    for workflows <- [["ci"], []] do
      assert {:error, :main_runs_incomplete} = GitHub.poll("main", workflows, request_fun: census_request(commits, [newer]), actions_write: false)
    end
  end

  test "paginated census rejects missing or invalid commit and run dates" do
    commit = %{"sha" => "new", "commit" => %{"committer" => %{"date" => "2026-10-10T00:00:00Z"}}}
    run = Map.put(run(1, "new", "ci", "completed", "success"), "created_at", "2026-10-10T00:00:00Z")

    for invalid <- [nil, "not-a-date", 123] do
      assert {:error, :main_runs_incomplete} = GitHub.poll("main", ["ci"], request_fun: census_request([put_in(commit, ["commit", "committer", "date"], invalid)], [run]), actions_write: false)
      assert {:error, :main_runs_incomplete} = GitHub.poll("main", ["ci"], request_fun: census_request([commit], [Map.put(run, "created_at", invalid)]), actions_write: false)
    end
  end

  test "pagination and provider errors cannot produce a partial green verdict" do
    for response <- [{:ok, %{status: 200, body: %{"workflow_runs" => []}, headers: [{"link", "<https://api.github.com/next>; rel=\"next\""}]}}, {:ok, %{status: 403, body: %{}}}] do
      request = fn %{url: url} -> if String.contains?(url, "/commits?"), do: ok([%{"sha" => "abc"}]), else: response end
      assert {:error, _} = GitHub.poll("main", [], request_fun: request, actions_write: false)
    end
  end

  test "rerun posts to Actions and never claims success on rejection" do
    parent = self()

    request = fn request ->
      send(parent, request)
      {:ok, %{status: 201, body: %{}}}
    end

    assert :ok = GitHub.rerun(42, request_fun: request)
    assert_received %{method: :post, url: "https://api.github.com/repos/owner/repo/actions/runs/42/rerun", caller: "main_watch_canary", body: %{}}
    assert {:error, {:github, :http, %{status: 403}}} = GitHub.rerun(42, request_fun: fn _ -> {:ok, %{status: 403, body: %{}}} end)
  end

  test "probe checks actual App installation permissions and fails closed on PAT and errors" do
    vars = ~w(GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_PRIVATE_KEY_PATH)
    previous = Map.new(vars, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> if value, do: System.put_env(key, value), else: System.delete_env(key) end) end)
    Enum.each(vars, &System.delete_env/1)
    refute GitHub.actions_write?(request_fun: fn _ -> flunk("PAT must not be probed as App") end)
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, pem} = JOSE.JWK.to_pem(key)
    System.put_env(%{"GITHUB_APP_ID" => "123", "GITHUB_APP_INSTALLATION_ID" => "456", "GITHUB_APP_PRIVATE_KEY" => pem})

    for permission <- ["read", "write", nil] do
      request = fn %{token: jwt, url: url, caller: "main_watch_permissions", credential_pinned?: true} ->
        assert url == "https://api.github.com/app/installations/456"
        assert JOSE.JWT.verify_strict(key, ["RS256"], jwt) |> elem(0)
        ok(%{"permissions" => %{"actions" => permission}})
      end

      assert GitHub.actions_write?(request_fun: request) == (permission == "write")
    end

    refute GitHub.actions_write?(request_fun: fn _ -> {:error, :closed} end)
    refute GitHub.actions_write?(request_fun: fn _ -> ok(%{"permissions" => "unknown"}) end)
  end

  defp census_request(commits, runs) do
    fn %{url: url} ->
      cond do
        String.contains?(url, "/commits?") -> ok(commits)
        String.contains?(url, "/actions/runs?") -> {:ok, %{status: 200, body: %{"workflow_runs" => runs}, headers: [{"link", "<https://api.github.com/next>; rel=\"next\""}]}}
        String.contains?(url, "/check-runs?") -> ok(%{"check_runs" => [check(1, 1, "success")]})
        String.ends_with?(url, "/status") -> ok(%{"statuses" => []})
        true -> flunk("must not fetch older pages: #{url}")
      end
    end
  end

  defp run(id, sha, name, status, conclusion),
    do: %{
      "id" => id,
      "head_sha" => sha,
      "head_branch" => "main",
      "event" => "push",
      "name" => name,
      "status" => status,
      "conclusion" => conclusion,
      "check_suite_id" => if(name == "ci", do: 1, else: 2),
      "updated_at" => "2026-10-10T00:00:00Z",
      "html_url" => "https://example.test/#{id}"
    }

  defp check(id, suite, conclusion), do: %{"id" => id, "name" => "test", "check_suite" => %{"id" => suite}, "app" => %{"slug" => "github-actions"}, "status" => "completed", "conclusion" => conclusion}
  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
