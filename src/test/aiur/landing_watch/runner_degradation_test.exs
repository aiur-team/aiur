defmodule Aiur.LandingWatch.RunnerDegradationTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.RunnerDegradation

  test "one timeout is not degraded and a healthy single failure remains eligible" do
    jobs = [%{"id" => 1, "name" => "test", "conclusion" => "failure"}]
    refute RunnerDegradation.degraded?(jobs, job_log_fun: fn _, _ -> {:ok, "** (ExUnit.TimeoutError) test timed out"} end)
    refute RunnerDegradation.degraded?(jobs, job_log_fun: fn _, _ -> {:ok, "assertion failed"} end)
  end

  test "three distinct ExUnit timeout tests in one job indicate runner degradation" do
    log = Enum.map_join(1..3, "\n", &"** (ExUnit.TimeoutError) test #{&1} timed out")
    assert RunnerDegradation.degraded?(failed_job(), job_log_fun: fn _, _ -> {:ok, log} end)
  end

  test "coverage partition hitting its time bound indicates runner degradation" do
    assert RunnerDegradation.degraded?(failed_job(), job_log_fun: fn _, _ -> {:ok, "Test coverage partition 3 exceeded its 20m bound"} end)
  end

  test "compile step slowdown compares step duration with the recent same-job median" do
    job = %{
      "id" => 1,
      "name" => "test",
      "conclusion" => "failure",
      "steps" => [%{"name" => "Compile", "started_at" => "2026-10-27T10:00:00Z", "completed_at" => "2026-10-27T10:03:00Z"}]
    }

    assert RunnerDegradation.degraded?([job], compile_median_fun: fn "test", "Compile", _ -> {:ok, 50} end)
    refute RunnerDegradation.degraded?([job], compile_median_fun: fn "test", "Compile", _ -> {:ok, 61} end)
  end

  test "recent compile-step median is memoized within one landing-watch poll" do
    parent = self()
    {:ok, cache} = Agent.start_link(fn -> %{} end)

    job = %{
      "id" => 1,
      "name" => "test",
      "conclusion" => "failure",
      "steps" => [%{"name" => "Compile", "started_at" => "2026-10-27T10:00:00Z", "completed_at" => "2026-10-27T10:03:00Z"}]
    }

    opts = [
      runner_degradation_cache: cache,
      compile_median_fun: fn _, _, _ ->
        send(parent, :median_read)
        {:ok, 50}
      end,
      job_log_fun: fn _, _ -> {:ok, ""} end
    ]

    assert RunnerDegradation.degraded?([job], opts)
    assert RunnerDegradation.degraded?([job], opts)
    assert_received :median_read
    refute_received :median_read
    Agent.stop(cache)
  end

  test "production log reader uses the governed Actions job-log request" do
    request = fn %{url: url, caller: caller} ->
      assert url =~ "/actions/jobs/1/logs"
      assert caller == "landing_watch_runner_degradation"
      {:ok, %{status: 200, body: "assertion failed"}}
    end

    refute RunnerDegradation.degraded?(failed_job(), token: "test-token", request_fun: request)
  end

  test "production compile median uses recent successful same-job steps through the bounded Actions caller" do
    actions_read = fn path, opts ->
      assert opts[:caller] == "landing_watch_runner_degradation"

      if String.contains?(path, "/actions/runs?") do
        assert path =~ "event=push"
        assert path =~ "per_page=5"
        {:ok, %{"workflow_runs" => [%{"id" => 9, "conclusion" => "success"}]}}
      else
        flunk("unexpected Actions read #{path}")
      end
    end

    actions_jobs = fn 9, opts ->
      assert opts[:caller] == "landing_watch_runner_degradation"
      {:ok, [%{"name" => "test", "steps" => [%{"name" => "Compile", "conclusion" => "success", "started_at" => "2026-10-27T10:00:00Z", "completed_at" => "2026-10-27T10:00:50Z"}]}]}
    end

    job = %{
      "id" => 1,
      "name" => "test",
      "conclusion" => "failure",
      "steps" => [%{"name" => "Compile", "started_at" => "2026-10-27T10:00:00Z", "completed_at" => "2026-10-27T10:03:00Z"}]
    }

    assert RunnerDegradation.degraded?([job], actions_read_fun: actions_read, actions_jobs_fun: actions_jobs)
  end

  defp failed_job, do: [%{"id" => 1, "name" => "test", "conclusion" => "failure"}]
end
