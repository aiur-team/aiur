defmodule Aiur.GitHub.CiReadiness.AssessmentTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.CiReadiness

  @workflow """
  name: CI
  on:
    pull_request:
      branches: [develop]
  jobs:
    test:
      name: ci / required
      runs-on: ubuntu-latest
      steps:
        - run: true
  """

  test "reads live ruleset and classic required check identities" do
    request_fun = fn %{url: url, caller: caller} ->
      assert caller == "ci_required_checks"

      if String.contains?(url, "/rules/branches/release%2Fnext") do
        {:ok, %{status: 200, body: [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "full", "integration_id" => 15_368}]}}]}}
      else
        assert String.ends_with?(url, "/branches/release%2Fnext/protection")
        {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["legacy"]}}}}
      end
    end

    assert {:ok, checks} = CiReadiness.fetch_required_checks(repo: "owner/repo", base_branch: "release/next", token: "test-gh-token", request_fun: request_fun)
    assert Enum.sort_by(checks, & &1.name) == [%{name: "full", app_id: 15_368}, %{name: "legacy", app_id: nil}]
    assert {:error, _reason} = CiReadiness.fetch_required_checks(repo: "owner/repo", token: "test-gh-token", request_fun: fn _ -> {:ok, %{status: 403, body: %{}}} end)
  end

  test "PR workflow runs seven fast jobs, including soak, and the event gate produces the required check" do
    root = Path.expand("../../../../..", __DIR__)
    workflow = File.read!(Path.join(root, ".github/workflows/ci.yml"))
    parsed = YamlElixir.read_from_string!(workflow)
    assert parsed["on"]["pull_request"]["types"] == ~w(opened synchronize reopened ready_for_review labeled)
    assert Map.has_key?(parsed["on"], "merge_group")
    assert parsed["on"]["push"]["branches"] == ["main", "v2"]
    gate = "needs.changes.outputs.full_ci == 'true'"
    fast = ~w(affected-tests changes ci-gate lint pre-handoff soak workflow-security)
    selected = for {id, job} <- parsed["jobs"], id != "quarantine", not String.contains?(Map.get(job, "if", ""), gate), do: id
    assert Enum.sort(selected) == fast

    for {id, job} <- parsed["jobs"], id not in fast and id != "quarantine" do
      assert String.contains?(job["if"], gate)
    end

    assert parsed["jobs"]["ci-gate"]["if"] =~ "always()"
    declaration = root |> Path.join("docs/security/human-only-merge-ruleset.json") |> File.read!() |> Jason.decode!()
    checks = declaration["rules"] |> Enum.find(&(&1["type"] == "required_status_checks")) |> get_in(["parameters", "required_status_checks"])
    readiness = CiReadiness.evaluate("main", [{".github/workflows/ci.yml", workflow}], checks)
    assert readiness.ready?
    assert readiness.required_checks == ["ci gate"]
  end

  test "reports a repository without a pull request workflow" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/push.yml", "on:\n  push:\n"}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "reports a workflow with no required check" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [])

    refute readiness.ready?
    assert :no_required_check in readiness.issues
  end

  test "reports required checks which no pull request workflow produces" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / aggregate"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / aggregate"]} in readiness.issues
  end

  test "accepts a matching required check from a configured pull request workflow" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])

    assert readiness.ready?
    assert readiness.workflow_paths == [".github/workflows/ci.yml"]
    assert readiness.required_checks == ["ci / required"]
  end

  test "rejects a required check pinned to a different integration" do
    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [
        %{"context" => "ci / required", "app_id" => 42}
      ])

    refute readiness.ready?
    assert readiness.required_check_identities == [%{name: "ci / required", app_id: 42}]
    assert {:required_check_integration_not_produced, ["ci / required (app_id: 42)"]} in readiness.issues
  end

  test "accepts a required check pinned to GitHub Actions" do
    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [
        %{"context" => "ci / required", "app_id" => 15_368}
      ])

    assert readiness.ready?
  end

  test "uses an operator assessment only for its exact repository, base, and config fingerprint" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, opts)
    assert :ok = CiReadiness.clear_cached_result()
    assert CiReadiness.cached_result(opts) == readiness
    assert CiReadiness.cached_result(Keyword.put(opts, :repo, "owner/other")) == :unavailable
    assert CiReadiness.cached_result(Keyword.put(opts, :base_branch, "main")) == :unavailable
    assert CiReadiness.cached_result(Keyword.put(opts, :config_fingerprint, "config-b")) == :unavailable
  end

  test "dispatch refreshes persisted readiness even when required checks are unchanged" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]
    original_token = System.get_env(CiReadiness.operator_token_env())
    System.put_env(CiReadiness.operator_token_env(), "operator-test-token")

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()

      if original_token do
        System.put_env(CiReadiness.operator_token_env(), original_token)
      else
        System.delete_env(CiReadiness.operator_token_env())
      end
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, opts)
    assert :ok = CiReadiness.clear_cached_result()

    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:readiness_request, url})

      cond do
        url =~ "/rules/branches/develop" ->
          {:ok, %{status: 200, body: [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci / required"}]}}]}}

        String.ends_with?(url, "/branches/develop/protection") ->
          {:ok, %{status: 404, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-content"}]}}

        url == "workflow-content?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => Base.encode64(@workflow)}}}

        url =~ "/actions/workflows" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/rulesets?" ->
          {:ok, %{status: 200, body: [%{"id" => 7}]}}

        url =~ "/rulesets/7" ->
          {:ok, %{status: 200, body: %{"rules" => [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci / required"}]}}]}}}

        true ->
          flunk("unexpected request: #{url}")
      end
    end

    assert {:ok, ^readiness} = CiReadiness.dispatch_check(Keyword.put(opts, :request_fun, request_fun))
    assert_received {:readiness_request, "workflow-content?ref=develop"}
  end

  test "dispatch reports the operator token required instead of accepting a persisted ready result" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])

    opts = [
      repo: "owner/repo",
      base_branch: "develop",
      config_fingerprint: "config-a",
      path: path,
      token: "test-gh-token",
      request_fun: fn _ -> flunk("readiness must not use daemon authentication") end
    ]

    original_token = System.get_env(CiReadiness.operator_token_env())
    System.delete_env(CiReadiness.operator_token_env())

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
      if original_token, do: System.put_env(CiReadiness.operator_token_env(), original_token), else: System.delete_env(CiReadiness.operator_token_env())
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, opts)
    assert {:ok, %{ready?: false} = unavailable} = CiReadiness.dispatch_check(opts)
    assert {:unavailable, :ci_readiness_operator_token_required} in unavailable.issues
    assert CiReadiness.format(unavailable) =~ CiReadiness.operator_token_env()
  end

  test "dispatch re-assesses when the live required check set changes" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    old = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]
    original_token = System.get_env(CiReadiness.operator_token_env())
    System.put_env(CiReadiness.operator_token_env(), "operator-test-token")

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
      if original_token, do: System.put_env(CiReadiness.operator_token_env(), original_token), else: System.delete_env(CiReadiness.operator_token_env())
    end)

    assert :ok = CiReadiness.persist_assessment(old, opts)
    assert :ok = CiReadiness.clear_cached_result()

    parent = self()

    request_fun = fn %{url: url} ->
      cond do
        url =~ "/rules/branches/develop" ->
          {:ok, %{status: 200, body: [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci gate"}]}}]}}

        String.ends_with?(url, "/branches/develop/protection") ->
          {:ok, %{status: 404, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-content"}]}}

        url == "workflow-content?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => Base.encode64(String.replace(@workflow, "ci / required", "ci gate"))}}}

        url =~ "/actions/workflows" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/rulesets?" ->
          {:ok, %{status: 200, body: [%{"id" => 7}]}}

        url =~ "/rulesets/7" ->
          {:ok, %{status: 200, body: %{"rules" => [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci gate"}]}}]}}}

        true ->
          send(parent, {:unexpected_url, url})
          {:error, :unexpected}
      end
    end

    assert {:ok, readiness} = CiReadiness.dispatch_check(Keyword.put(opts, :request_fun, request_fun))
    assert readiness.required_checks == ["ci gate"]
  end

  test "expires an unchanged-config assessment and detects a removed pull request gate" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    now = DateTime.utc_now()
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path, now: now]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, Keyword.put(opts, :now, DateTime.add(now, -3_601, :second)))

    assert {:ok, %{issues: [{:unavailable, :ci_readiness_operator_token_required}]}} = CiReadiness.dispatch_check(opts)
  end

  test "a newer persisted operator assessment replaces the live memory result" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    now = DateTime.utc_now()
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path, now: now]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.cache_result(CiReadiness.unavailable("develop", :ci_readiness_operator_token_required), opts)

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "assessed_at" => DateTime.to_iso8601(DateTime.add(now, 1, :second)),
        "scope" => %{"repo" => "owner/repo", "base_branch" => "develop", "config_fingerprint" => "config-a"},
        "result" => %{
          "ready" => true,
          "base_branch" => "develop",
          "workflow_paths" => readiness.workflow_paths,
          "workflow_check_names" => readiness.workflow_check_names,
          "required_checks" => readiness.required_checks,
          "required_check_identities" => readiness.required_check_identities,
          "issues" => []
        }
      })
    )

    assert CiReadiness.cached_result(Keyword.put(opts, :now, DateTime.add(now, 1, :second))) == readiness
  end

  test "bounds the complete inspection, including a blocked request" do
    request_fun = fn _request ->
      Process.sleep(50)
      {:ok, %{status: 200, body: %{}}}
    end

    assert {:error, {:github, :timeout, _}} =
             CiReadiness.check(repo: "owner/repo", base_branch: "develop", token: "test-gh-token", request_fun: request_fun, timeout_ms: 1)
  end

  test "formats a ready assessment for operator status output" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])

    assert CiReadiness.format(readiness) =~ "CI readiness: ready for develop"
    assert CiReadiness.format(readiness) =~ "ci / required"
  end

  test "formats an inspection that never produced an assessment" do
    assert CiReadiness.format(:never_ran) =~ "CI readiness: unavailable"
  end

  test "treats an integration-pinned required check as a different GitHub App" do
    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [
        %{"context" => "ci / required", "integration_id" => 99}
      ])

    refute readiness.ready?
    assert readiness.required_check_identities == [%{name: "ci / required", app_id: 99}]
    assert {:required_check_integration_not_produced, ["ci / required (app_id: 99)"]} in readiness.issues
  end

  test "accepts an atom-keyed required check identity" do
    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [
        %{context: "ci / required"}
      ])

    assert readiness.ready?
  end

  test "persists and reloads an assessment carrying every issue shape" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"

    readiness = %{
      ready?: false,
      base_branch: "develop",
      workflow_paths: [],
      workflow_check_names: [],
      required_checks: ["ci / required"],
      required_check_identities: [%{name: "ci / required", app_id: 42}],
      issues: [
        :no_pr_workflow,
        {:required_check_not_produced, ["ci / required"]},
        {:required_check_integration_not_produced, ["ci / required (app_id: 42)"]}
      ]
    }

    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, opts)
    assert :ok = CiReadiness.clear_cached_result()
    assert CiReadiness.cached_result(opts) == readiness
  end

  test "ignores a persisted assessment whose result cannot be decoded" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "assessed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "scope" => %{"repo" => "owner/repo", "base_branch" => "develop", "config_fingerprint" => "config-a"},
        "result" => %{"ready" => "not-a-boolean", "base_branch" => 5}
      })
    )

    assert CiReadiness.cached_result(opts) == :unavailable
  end

  test "round-trips an unavailable operator assessment through persistence" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    readiness = CiReadiness.unavailable("develop", :ci_readiness_operator_token_required)
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, opts)
    assert :ok = CiReadiness.clear_cached_result()

    assert %{issues: [{:unavailable, reason}]} = CiReadiness.cached_result(opts)
    assert reason =~ "ci_readiness_operator_token_required"
    assert CiReadiness.format(CiReadiness.cached_result(opts)) =~ CiReadiness.operator_token_env()
  end

  test "reports an unknown persisted issue instead of silently dropping the assessment" do
    path = Aiur.TestSupport.tmp_root!("aiur-ci-readiness") <> ".json"
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "assessed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "scope" => %{"repo" => "owner/repo", "base_branch" => "develop", "config_fingerprint" => "config-a"},
        "result" => %{
          "ready" => false,
          "base_branch" => "develop",
          "workflow_paths" => [],
          "workflow_check_names" => [],
          "required_checks" => [],
          "required_check_identities" => [],
          "issues" => [%{"type" => "mystery_issue"}]
        }
      })
    )

    assert CiReadiness.cached_result(opts) == :unavailable
  end
end
