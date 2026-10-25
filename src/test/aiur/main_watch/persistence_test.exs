defmodule Aiur.MainWatch.PersistenceTest do
  use Aiur.TestSupport
  alias Aiur.CI.FailureDigest
  alias Aiur.GitHub.ResourceStore
  alias Aiur.MainWatch.{Persistence, State}

  test "disk restart retains red signature, inherited history and pending publication" do
    root = Aiur.TestSupport.tmp_root!("aiur-main-watch-persistence")
    path = Path.join(root, "resources.json")
    previous_path = :sys.get_state(ResourceStore).path

    on_exit(fn ->
      restart_store(previous_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    restart_store(path)
    now = System.system_time(:millisecond)
    observation = observation("red", now)
    {state, pending} = State.observe(State.new(), observation, now)

    data = %{
      Persistence.empty()
      | state: state,
        pending: pending,
        commits: ["red", "green"],
        commit_window: ["red", "green"],
        commit_dates: [now, now - 1_000],
        commit_etag: "\"main-v1\"",
        canary_at: now,
        last_completed_at: now
    }

    assert :ok = Persistence.save("owner/repo", "main", data)
    assert {:ok, document} = path |> File.read!() |> Jason.decode()
    assert Map.has_key?(document["entries"], "main_watch|owner|repo|main")

    assert :ok = Persistence.reserve_rerun("owner/repo", "main:canary", now, 60_000)
    restart_store(path)
    assert {:error, :already_attempted} = Persistence.reserve_rerun("owner/repo", "main:canary", now + 1, 60_000)
    assert :ok = Persistence.reserve_rerun("owner/repo", "main:canary", now + 60_000, 60_000)
    restored = Persistence.load("owner/repo", "main")
    assert restored == data
    assert [{"system.main.ci.failed", %{sha: "red", failing_tests: :unknown}}] = restored.pending
    assert [%{sha: "red", checks: [%{name: "test", conclusion: "failure"}]}] = restored.state.history
    assert {next, []} = State.observe(restored.state, observation("next", now + 1), now + 1)
    assert next.sha == "next"
  end

  defp restart_store(path) do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)
    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
  end

  defp observation(sha, now) do
    %{
      sha: sha,
      completed_at: now,
      checks: [%{name: "test", conclusion: "failure"}],
      digest: %FailureDigest{signature: "unknown-test", tests: :unknown},
      run_urls: ["https://github.example/runs/" <> sha],
      suspect_merges: []
    }
  end
end
