defmodule Aiur.Tracker.FacadeConditionalTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Orchestrator.Dispatcher.Candidates

  defmodule Adapter do
    def fetch_candidate_issues_conditional(cache), do: {:ok, [%Aiur.Issue{id: "7", queued: true}], Map.put(cache, :renewed, true)}
    def hydrate_blocked_by(_issue), do: {:error, :dependency_unavailable}
    def with_transient_retry(fun, opts), do: {Keyword.fetch!(opts, :marker), fun.()}
  end

  setup do
    saved = for key <- [:memory_tracker_issues, :tracker_adapters, :github_client_module], do: {key, Application.fetch_env(:aiur, key)}
    scope = System.get_env("AIUR_DEV_TEST_TICKET_IDS")

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end

      if scope, do: System.put_env("AIUR_DEV_TEST_TICKET_IDS", scope), else: System.delete_env("AIUR_DEV_TEST_TICKET_IDS")
    end)

    :ok
  end

  test "memory candidates preserve cache and apply the test ticket scope" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: "7", identifier: "7", queued: true}
    Application.put_env(:aiur, :memory_tracker_issues, [issue, %Issue{id: "8", identifier: "8"}])
    System.put_env("AIUR_DEV_TEST_TICKET_IDS", "7")
    cache = %{etag: "held"}

    assert {:ok, [^issue], ^cache} = Tracker.fetch_candidate_issues_conditional(cache)
    assert {:ok, [^issue], ^cache} = Candidates.default_candidate_fetch(cache)
  end

  test "hydration passes through when config is unavailable" do
    missing = Path.join(Path.dirname(Workflow.workflow_file_path()), "missing-config")
    Workflow.set_workflow_file_path(missing, reload: false)
    assert {:error, _reason} = Config.settings()
    issue = %Issue{id: "7", blocked_by: [%{id: "6", state: "todo"}]}

    assert {:ok, ^issue} = Tracker.hydrate_blocked_by(issue)
    assert {:ok, ^issue} = Candidates.default_blocked_by_hydrator(issue)
  end

  test "optional memory hydration and retry fall back without altering the result" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: "7"}
    assert {:ok, ^issue} = Tracker.hydrate_blocked_by(issue)
    assert {:error, :unavailable} = Tracker.with_transient_retry(fn -> {:error, :unavailable} end, [])
  end

  test "registered callbacks preserve queued candidates, renewed cache and hydration errors" do
    Application.put_env(:aiur, :tracker_adapters, %{"custom" => Adapter})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "custom")

    # Future regression guard: never reconstruct ingested candidates and lose queued.
    assert {:ok, [%Issue{id: "7", queued: true}], %{held: true, renewed: true}} =
             Candidates.default_candidate_fetch(%{held: true})

    assert {:error, :dependency_unavailable} = Candidates.default_blocked_by_hydrator(%Issue{id: "7"})
    assert {:delegated, :result} = Tracker.with_transient_retry(fn -> :result end, marker: :delegated)
  end

  test "github retry waits out a local hold and preserves caller options" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    issue = %Issue{id: "7"}
    reset_at = DateTime.add(DateTime.utc_now(), 5, :second)
    hold = {:error, {:github, :local_hold, %{hold: %{reset_at: reset_at}}}}
    Process.put(:facade_attempts, [hold, {:ok, [issue]}])
    Process.put(:facade_sleeps, [])

    fun = fn ->
      [result | rest] = Process.get(:facade_attempts)
      Process.put(:facade_attempts, rest)
      result
    end

    opts = [local_hold_sleep_fun: fn ms -> Process.put(:facade_sleeps, [ms | Process.get(:facade_sleeps)]) end]
    assert {:ok, [^issue]} = Tracker.with_transient_retry(fun, opts)
    assert [] = Process.get(:facade_attempts)
    assert [sleep_ms] = Process.get(:facade_sleeps)
    assert sleep_ms > 0 and sleep_ms <= 60_000
  end

  test "github conditional fetch and hydration use the client through the facade" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    Application.put_env(:aiur, :github_client_module, Adapter)

    assert {:ok, [%Issue{id: "7", queued: true}], %{renewed: true}} = Tracker.fetch_candidate_issues_conditional(%{})
    assert {:error, :dependency_unavailable} = Tracker.hydrate_blocked_by(%Issue{id: "7"})
  end
end
