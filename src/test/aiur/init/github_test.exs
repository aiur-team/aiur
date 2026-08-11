defmodule Aiur.Init.GitHubTest do
  use ExUnit.Case

  alias Aiur.Init.GitHub

  describe "parse_repo/1" do
    test "parses SSH URL" do
      assert GitHub.parse_repo("git@github.com:o/r.git") == "o/r"
    end

    test "parses HTTPS URL with .git suffix" do
      assert GitHub.parse_repo("https://github.com/o/r.git") == "o/r"
    end

    test "parses HTTPS URL without .git suffix" do
      assert GitHub.parse_repo("https://github.com/o/r") == "o/r"
    end

    test "returns nil for garbage input" do
      assert GitHub.parse_repo("garbage") == nil
    end
  end

  describe "parse_owner_repo/1" do
    test "parses owner/name string" do
      assert GitHub.parse_owner_repo("o/r") == {:ok, {"o", "r"}}
    end

    test "returns error for nil" do
      {:error, msg} = GitHub.parse_owner_repo(nil)
      assert msg =~ ".aiur/config"
    end

    test "returns error for non-slash string" do
      {:error, msg} = GitHub.parse_owner_repo("nope")
      assert msg =~ ".aiur/config"
    end
  end

  describe "detect_default_branch/2" do
    test "reads the repository default branch from the GitHub API" do
      command_fun = fn "gh", ["api", "repos/o/r", "--jq", ".default_branch"], [stderr_to_stdout: true] ->
        {"develop\n", 0}
      end

      assert GitHub.detect_default_branch("o/r", command_fun) == "develop"
    end

    test "returns nil when the API request fails or has no branch" do
      assert GitHub.detect_default_branch("o/r", fn _command, _args, _opts -> {"denied", 1} end) == nil
      assert GitHub.detect_default_branch("o/r", fn _command, _args, _opts -> {"\n", 0} end) == nil
    end

    test "does not derive a repository-specific default for global config" do
      assert GitHub.detect_default_branch(nil, fn _command, _args, _opts -> flunk("GitHub API should not be called") end) == nil
    end
  end

  describe "ensure_ci_readiness/3" do
    test "warns when a last-push gate has only one bot identity" do
      parent = self()
      io = %{puts: fn message -> send(parent, {:io_puts, message}) end, confirm: fn _, _ -> false end}

      readiness = %{ready?: true, base_branch: "main", required_checks: [], merge_gate: %{require_last_push_approval?: true}}
      deps = %{check_ci_readiness: fn _ -> {:ok, readiness} end, detect_repo: fn -> "o/r" end}
      tracker = %{kind: "github", repo: "o/r", bot_account: "push-bot", review_bot_account: nil, human_mergers: []}

      assert :ok = GitHub.ensure_ci_readiness(io, deps, tracker)
      assert_received {:io_puts, _readiness}
      assert_received {:io_puts, warning}
      assert warning =~ "three principals"
      assert warning =~ "review_bot_account"
      assert warning =~ "credential-split-merge-gate.md"
    end

    test "keeps CI-readiness administration access separate from the daemon token" do
      io = %{puts: fn _ -> :ok end, confirm: fn _, _ -> false end}
      deps = %{check_ci_readiness: fn _ -> {:error, {:github, :http, %{status: 403}}} end, detect_repo: fn -> "o/r" end}

      assert {:error, message} = GitHub.ensure_ci_readiness(io, deps, %{kind: "github", repo: "o/r"})
      assert message =~ "AIUR_CI_READINESS_TOKEN"
      assert message =~ "do not grant"
    end

    test "persists a ready operator assessment for the daemon and reports it" do
      root = Path.join(System.tmp_dir!(), "aiur-init-readiness-#{System.unique_integer([:positive])}")
      config_path = Path.join([root, "aiur", "config.yml"])
      parent = self()
      io = %{puts: fn msg -> send(parent, {:io_puts, msg}) end, confirm: fn _, _ -> false end}

      readiness = %{
        ready?: true,
        base_branch: "main",
        workflow_paths: [".github/workflows/ci.yml"],
        workflow_check_names: ["ci / required"],
        required_checks: ["ci / required"],
        required_check_identities: [],
        issues: []
      }

      deps = %{check_ci_readiness: fn _ -> {:ok, readiness} end, detect_repo: fn -> "o/r" end}
      tracker = %{kind: "github", repo: "o/r", base_branch: "main", config_path: config_path}

      original_token = System.get_env("AIUR_CI_READINESS_TOKEN")
      System.put_env("AIUR_CI_READINESS_TOKEN", "operator-token")

      on_exit(fn ->
        File.rm_rf!(root)

        if original_token do
          System.put_env("AIUR_CI_READINESS_TOKEN", original_token)
        else
          System.delete_env("AIUR_CI_READINESS_TOKEN")
        end
      end)

      assert :ok = GitHub.ensure_ci_readiness(io, deps, tracker)
      assert_received {:io_puts, msg}
      assert msg =~ "CI readiness: ready for main"
      assert File.exists?(Path.join([root, "aiur", "ci-readiness.json"]))
    end

    test "offers to scaffold a CI workflow when the repository has none" do
      root = Path.join(System.tmp_dir!(), "aiur-init-readiness-#{System.unique_integer([:positive])}")
      config_path = Path.join([root, "aiur", "config.yml"])
      parent = self()
      io = %{puts: fn msg -> send(parent, {:io_puts, msg}) end, confirm: fn _, _ -> true end}

      readiness = %{
        ready?: false,
        base_branch: "main",
        workflow_paths: [],
        workflow_check_names: [],
        required_checks: [],
        required_check_identities: [],
        issues: [:no_pr_workflow, :no_required_check]
      }

      deps = %{
        check_ci_readiness: fn _ -> {:ok, readiness} end,
        detect_repo: fn -> "o/r" end,
        repo_root: fn -> root end
      }

      tracker = %{kind: "github", repo: "o/r", base_branch: "main", config_path: config_path}

      on_exit(fn -> File.rm_rf!(root) end)

      assert {:error, message} = GitHub.ensure_ci_readiness(io, deps, tracker)
      assert message =~ "Repository CI readiness is incomplete"
      assert File.exists?(Path.join([root, ".github", "workflows", "ci.yml"]))

      assert_received {:io_puts, setup_msg}
      assert setup_msg =~ "CI readiness setup error"

      assert_received {:io_puts, created_msg}
      assert created_msg =~ "Created"
    end

    test "explains the operator token gap when a PR workflow needs privileged inspection" do
      io = %{puts: fn _ -> :ok end, confirm: fn _, _ -> false end}
      deps = %{check_ci_readiness: fn _ -> {:error, :ci_readiness_operator_token_required} end}

      assert {:error, message} = GitHub.ensure_ci_readiness(io, deps, %{kind: "github", repo: "o/r"})
      assert message =~ "operator-only AIUR_CI_READINESS_TOKEN"
      assert message =~ "GITHUB_TOKEN"
    end

    test "skips the CI scaffold when a workflow already exists" do
      root = Path.join(System.tmp_dir!(), "aiur-init-readiness-#{System.unique_integer([:positive])}")
      config_path = Path.join([root, "aiur", "config.yml"])
      parent = self()
      io = %{puts: fn msg -> send(parent, {:io_puts, msg}) end, confirm: fn _, _ -> true end}
      workflow_path = Path.join([root, ".github", "workflows", "ci.yml"])
      File.mkdir_p!(Path.dirname(workflow_path))
      File.write!(workflow_path, "name: existing\n")

      readiness = %{
        ready?: false,
        base_branch: "main",
        workflow_paths: [],
        workflow_check_names: [],
        required_checks: [],
        required_check_identities: [],
        issues: [:no_pr_workflow]
      }

      deps = %{
        check_ci_readiness: fn _ -> {:ok, readiness} end,
        detect_repo: fn -> "o/r" end,
        repo_root: fn -> root end
      }

      tracker = %{kind: "github", repo: "o/r", base_branch: "main", config_path: config_path}

      on_exit(fn -> File.rm_rf!(root) end)

      assert {:error, _message} = GitHub.ensure_ci_readiness(io, deps, tracker)

      assert_received {:io_puts, setup_msg}
      assert setup_msg =~ "CI readiness setup error"

      assert_received {:io_puts, skipped_msg}
      assert skipped_msg =~ "CI scaffold skipped"
      assert File.read!(workflow_path) == "name: existing\n"
    end

    test "reports a CI scaffold write failure" do
      root = Path.join(System.tmp_dir!(), "aiur-init-readiness-#{System.unique_integer([:positive])}")
      config_path = Path.join([root, "aiur", "config.yml"])
      parent = self()
      io = %{puts: fn msg -> send(parent, {:io_puts, msg}) end, confirm: fn _, _ -> true end}
      # Make the workflows directory an unwritable regular file so mkdir fails.
      File.mkdir_p!(Path.join(root, ".github"))
      File.write!(Path.join([root, ".github", "workflows"]), "not a directory")

      readiness = %{
        ready?: false,
        base_branch: "main",
        workflow_paths: [],
        workflow_check_names: [],
        required_checks: [],
        required_check_identities: [],
        issues: [:no_pr_workflow]
      }

      deps = %{
        check_ci_readiness: fn _ -> {:ok, readiness} end,
        detect_repo: fn -> "o/r" end,
        repo_root: fn -> root end
      }

      tracker = %{kind: "github", repo: "o/r", base_branch: "main", config_path: config_path}

      on_exit(fn -> File.rm_rf!(root) end)

      assert {:error, _message} = GitHub.ensure_ci_readiness(io, deps, tracker)

      assert_received {:io_puts, setup_msg}
      assert setup_msg =~ "CI readiness setup error"

      assert_received {:io_puts, error_msg}
      assert error_msg =~ "CI scaffold could not be written"
    end
  end

  describe "label_error_message/1" do
    test "403 mentions token scope" do
      msg = GitHub.label_error_message({:github_api_status, 403, "agent:todo"})
      assert msg =~ "403"
      assert msg =~ "scope"
    end

    test "404 mentions .aiur/config" do
      msg = GitHub.label_error_message({:github_api_status, 404, "agent:todo"})
      assert msg =~ "404"
      assert msg =~ ".aiur/config"
    end

    test "other status returns generic message" do
      msg = GitHub.label_error_message({:github_api_status, 500, "x"})
      assert msg =~ "500"
    end

    test "request error mentions reason" do
      msg = GitHub.label_error_message({:github_api_request, :timeout})
      assert msg =~ "timeout"
    end

    test "unknown term is inspected" do
      msg = GitHub.label_error_message(:something_else)
      assert msg =~ "something_else"
    end
  end

  describe "require_github_token/0" do
    @tag :not_async
    test "returns error when GITHUB_TOKEN not set" do
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)
      {:error, msg} = GitHub.require_github_token()
      assert msg =~ ".env"
    end

    @tag :not_async
    test "returns ok when GITHUB_TOKEN is set" do
      System.put_env("GITHUB_TOKEN", "tok")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)
      assert GitHub.require_github_token() == {:ok, "tok"}
    end
  end

  describe "detect_bot_account/1" do
    @tag :not_async
    test "returns nil when no GITHUB_TOKEN is set (never calls the viewer lookup)" do
      System.delete_env("GITHUB_TOKEN")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req -> flunk("viewer lookup must not run without a token") end
      assert GitHub.detect_bot_account(request_fun) == nil
    end

    @tag :not_async
    test "returns nil on a viewer-lookup failure without surfacing the token" do
      System.put_env("GITHUB_TOKEN", "ghp_supersecret")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req -> {:error, :boom} end
      assert GitHub.detect_bot_account(request_fun) == nil
    end

    @tag :not_async
    test "returns nil when the request raises rather than crashing" do
      System.put_env("GITHUB_TOKEN", "ghp_supersecret")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req -> raise "network down" end
      assert GitHub.detect_bot_account(request_fun) == nil
    end

    @tag :not_async
    test "normalizes the resolved viewer login" do
      System.put_env("GITHUB_TOKEN", "ghp_supersecret")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      request_fun = fn _req ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "Its-AppleKid"}}}}}
      end

      assert GitHub.detect_bot_account(request_fun) == "its-applekid"
    end
  end

  describe "detect_repo/0" do
    test "returns owner/name from git remote" do
      dir = System.tmp_dir!() |> Path.join("detect-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      System.cmd("git", ["init"], cd: dir)
      System.cmd("git", ["remote", "add", "origin", "git@github.com:o/r.git"], cd: dir)

      result = File.cd!(dir, fn -> GitHub.detect_repo() end)
      assert result == "o/r"
    end

    test "returns nil when no origin remote" do
      dir = System.tmp_dir!() |> Path.join("detect-repo-noremote-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      System.cmd("git", ["init"], cd: dir)

      result = File.cd!(dir, fn -> GitHub.detect_repo() end)
      assert result == nil
    end
  end

  describe "list_repo_labels/1 and create_labels/2" do
    test "list_repo_labels returns {:ok, []} for non-github tracker" do
      assert GitHub.list_repo_labels(%{kind: "memory"}) == {:ok, []}
    end

    test "create_labels returns :ok for non-github tracker" do
      assert GitHub.create_labels(%{kind: "memory"}, ["agent:todo"]) == :ok
    end
  end
end
