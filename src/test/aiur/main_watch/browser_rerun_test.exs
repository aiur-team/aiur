defmodule Aiur.MainWatch.BrowserRerunTest do
  use Aiur.TestSupport
  alias Aiur.CI.FailureDigest
  alias Aiur.MainWatch

  test "a single annotated browser spec on an untouched file reruns its failed job" do
    parent = self()

    digest = %FailureDigest{
      signature: "browser-single",
      test_only: true,
      tests: [%{identity: "BrowserSpec :: src/browser/tests/recovery.browser.spec.mjs", path: "src/browser/tests/recovery.browser.spec.mjs", classification: :new_failure}]
    }

    failed = observation("browser-single-failure", digest)
    run = %{id: 44, sha: "browser-single-failure", attempt: 1, status: "completed", conclusion: "failure", completed_at: 1, url: "run"}
    server = launch(parent, run.id)

    poll(server, parent, failed, run)
    assert_received {:browser_failed_job_rerun, 44}
    assert_received {:emitted, "system.main.ci.flake_rerun", %{sha: "browser-single-failure"}}
  end

  defp launch(parent, run_id) do
    poll = fn _, _, _ ->
      send(parent, {:poll_worker, self()})
      receive do: ({:complete, result} -> result)
    end

    {:ok, server} =
      MainWatch.start_link(
        name: nil,
        config: %{workflows: [], canary_minutes: 0},
        branch: "main",
        repo: "owner/repo",
        interval_ms: 60_000,
        debounce_ms: 0,
        subscribe: false,
        actions_write: true,
        load_fun: fn _, _ -> Aiur.MainWatch.Persistence.empty() end,
        poll_fun: poll,
        save_fun: fn _, _, data ->
          send(parent, {:saved, data})
          :ok
        end,
        emit_fun: fn topic, payload ->
          send(parent, {:emitted, topic, payload})
          :ok
        end,
        now_fun: fn -> 0 end,
        suspects_fun: fn _, _, _, _, _ -> [] end,
        changed_paths_fun: fn _, _ -> {:ok, ["src/browser/tests/other.browser.spec.mjs"]} end,
        reserve_single_test_rerun_fun: fn _, _, _, _ -> :ok end,
        rerun_failed_jobs_fun: fn ^run_id, _ ->
          send(parent, {:browser_failed_job_rerun, run_id})
          :ok
        end
      )

    server
  end

  defp poll(server, _parent, observation, run) do
    assert_receive {:poll_worker, worker}, 1_000
    send(worker, {:complete, {:ok, %{observations: [observation], commits: [observation.sha], runs: [run], actions_write: true}}})
    assert_receive {:saved, _}, 1_000
    MainWatch.state(server)
  end

  defp observation(sha, digest) do
    %{sha: sha, completed_at: 1, checks: [%{name: "test", conclusion: "failure"}], digest: digest, run_urls: ["run"]}
  end
end
