defmodule Aiur.TestSupportIsolationTest do
  @moduledoc """
  Regression guard for the per-test log/state isolation that `Aiur.TestSupport`
  sets up (fix/ci-flaky-tests).

  `SessionHandle` resume files and per-issue logs live under `Paths.log_root_dir/0`,
  which defaults to the shared `<cwd>/log`. A leaked `<repo>.<id>.session.json`
  there makes the agent runner resume a prior thread instead of cold-starting —
  the order-dependent `core_test` flakiness that only surfaces in per-file/subset
  runs (the full suite CI runs happens to mask it). `TestSupport.setup` points
  `:log_file` at the per-test workflow root to close that leak; if that line is
  ever removed the full suite still passes, so this invariant needs its own
  assertion to catch the regression.

  The pause-store assertion likewise protects cwd-changing tests from selecting
  a different implicit production store during teardown.
  """
  use Aiur.TestSupport

  alias Aiur.Config.Paths
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.GitHub.Issues
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.GlobalPauseStore

  @dispatch_cache_key {Aiur.GitHub.DispatchAuthorization, :timeline_cache}

  test "log_root_dir is isolated to the per-test workflow root, not <cwd>/log" do
    log_root = Paths.log_root_dir()

    refute log_root == Path.join(File.cwd!(), "log")
    assert String.ends_with?(log_root, "/log")
    assert String.contains?(log_root, "aiur-elixir-tests")
  end

  test "global pause persistence is isolated to the per-test workflow root" do
    path = GlobalPauseStore.path_for()

    assert path == Application.fetch_env!(:aiur, :global_pause_store_path)
    assert String.contains?(path, "aiur-elixir-tests")
    assert String.ends_with?(path, "/state/global-pause.json")
    assert {:ok, %{globally_paused: false}} = GlobalPauseStore.load()

    assert :ok =
             GlobalPauseStore.save(%{
               globally_paused: true,
               paused_at: DateTime.utc_now(),
               source: "test"
             })

    assert {:ok, %{globally_paused: true, source: "test"}} = GlobalPauseStore.load()
  end

  test "ModelAvailability reads and writes its default ledger store in the per-test workflow root" do
    workflow_dir = Path.dirname(Aiur.Workflow.workflow_file_path())
    default = ModelAvailability.path()

    # The default ledger path is derived from the active workflow directory —
    # the store this case actually reads and writes. This is deliberately wired
    # through the default path options (no explicit `path:` overrides), so a
    # mutation that stops reading this store — a constant path, an in-memory
    # copy, or a load that ignores the file — breaks the assertions below.
    assert default == Path.join(workflow_dir, "model-usage.json")
    refute String.contains?(default, "src/test/fixtures")

    assert :ok = ModelAvailability.observe("codex", %{weekly: %{used: 100, limit: 100}})

    assert File.regular?(default)
    assert %{"backends" => %{"codex" => %{"weekly" => %{"used" => 100}}}} = ModelAvailability.load()
  end

  test "process lifecycle waits synchronize on DOWN instead of polling" do
    test_support = File.read!(Path.expand("../support/test_support.exs", __DIR__))
    refute test_support =~ "Process.sleep("

    process = spawn(fn -> receive do: (:stop -> :ok) end)
    waiter = Task.async(fn -> Aiur.TestSupport.await_process_down(process, 1_000) end)

    assert Task.yield(waiter, 0) == nil
    send(process, :stop)
    assert {:ok, :ok} = Task.yield(waiter, 1_000)
  end

  # Regression guard for #2082. `DispatchAuthorization` keeps its decision cache
  # in `:persistent_term` and only exposes `clear_cache/0`; nothing in the
  # per-case setup used to call it, so a timeline decision one case made for an
  # issue was reused by a later case fetching the same issue id with the same
  # label and `updated_at`. That is what made `issues_test.exs` pass alone but
  # fail once a sibling file ran first in the same VM: the leaked cache changed
  # whether a test went down the live timeline-fetch path. The two tests below
  # run in definition order — the first deliberately leaves a populated cache
  # behind, and the second proves the next case's setup cleared it.
  test "a live DispatchAuthorization decision stays cached for the rest of the VM" do
    gh_issue = %{
      "number" => 2082,
      "node_id" => "I_kwDOIssue2082",
      "title" => "Leak probe",
      "html_url" => "https://github.com/owner/repo/issues/2082",
      "labels" => [%{"name" => "sym:todo"}],
      "state" => "open",
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }

    request_fun = fn %{url: url} ->
      if String.ends_with?(url, "/timeline?per_page=100") do
        {:ok,
         %{
           status: 200,
           headers: [],
           body: [
             %{
               "event" => "labeled",
               "id" => 1,
               "created_at" => "2026-01-01T00:00:00Z",
               "actor" => %{"login" => "trusted"},
               "label" => %{"name" => "sym:todo"}
             }
           ]
         }}
      else
        {:ok, %{status: 200, headers: [], body: %{}}}
      end
    end

    _ =
      Issues.normalize_issue(gh_issue, "owner", "repo", "sym")
      |> DispatchAuthorization.authorize("owner", "repo", "sym",
        request_fun: request_fun,
        token: "test-token"
      )

    assert :persistent_term.get(@dispatch_cache_key, :unset) != :unset
  end

  test "the next TestSupport case starts with an empty DispatchAuthorization cache" do
    assert :persistent_term.get(@dispatch_cache_key, :unset) == :unset
  end
end
