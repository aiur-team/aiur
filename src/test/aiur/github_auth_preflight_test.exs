defmodule Aiur.GitHubAuthPreflightTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Client

  defmodule FailingPreflightClient do
    def preflight_auth do
      {:error,
       {:github_auth_preflight_failed,
        %{
          reason: :invalid_or_expired_token,
          endpoint: :issues,
          repo: "owner/repo",
          token_source: "GITHUB_TOKEN",
          status: 401,
          gh_keyring_status: :available,
          message: "GitHub auth preflight failed for GITHUB_TOKEN while validating owner/repo issues access. Aiur uses GITHUB_TOKEN and it takes precedence over `gh` keyring auth."
        }}}
    end

    def fetch_candidate_issues do
      if pid = Application.get_env(:aiur, :github_auth_preflight_test_pid) do
        send(pid, :candidate_fetch_called)
      end

      {:ok, []}
    end
  end

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    Application.put_env(:aiur, :github_client_module, FailingPreflightClient)
    Application.put_env(:aiur, :github_auth_preflight_test_pid, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    on_exit(fn ->
      Application.delete_env(:aiur, :github_client_module)
      Application.delete_env(:aiur, :github_auth_preflight_test_pid)
      restore_env("GITHUB_TOKEN", prev_token)
    end)

    :ok
  end

  test "orchestrator stops before candidate polling when GitHub auth preflight fails" do
    orchestrator_name = Module.concat(__MODULE__, :PreflightOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)
        # Barrier: a synchronous system message queues behind :run_poll_cycle,
        # so this returns only after the cycle (and its preflight Logger.error)
        # has been fully handled — deterministic vs. a fixed sleep.
        _ = :sys.get_state(pid)
      end)

    assert log =~ "GitHub auth preflight failed for GITHUB_TOKEN"
    assert log =~ "takes precedence over `gh` keyring auth"
    refute log =~ "test-gh-token"
    refute_received :candidate_fetch_called
  end

  test "preflight formatter handles plain reasons for logging fallback" do
    assert Client.format_auth_preflight_error(:missing_github_token) == ":missing_github_token"
  end
end
