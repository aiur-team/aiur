defmodule Aiur.RunTelemetry.RepoTimelineRetryTest do
  use ExUnit.Case, async: false

  alias Aiur.RunTelemetry.RepoTimeline

  setup do
    root = Aiur.TestSupport.tmp_root!("timeline-retry")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "persistent failures bound requests with doubling delays capped at the hourly interval", %{root: root} do
    parent = self()
    calls = :atomics.new(1, [])

    request = fn _ ->
      send(parent, {:attempt, :atomics.add_get(calls, 1, 1)})
      {:error, :timeout}
    end

    worker =
      start_supervised!(
        {RepoTimeline,
         name: nil,
         path: Path.join(root, "timeline.ndjson"),
         repo: "owner/repo",
         branch: "main",
         token: "test",
         request_fun: request,
         enabled_fun: fn -> true end,
         boot_capture: false,
         retry_ms: 80,
         interval_ms: 320}
      )

    assert {:error, {:github, :timeout, _}} = RepoTimeline.capture(worker)
    assert_receive {:attempt, 1}, 500
    assert_receive {:attempt, 2}, 1_000
    refute_receive {:attempt, 3}, 120
    assert_receive {:attempt, 3}, 1_000
    refute_receive {:attempt, 4}, 240
    assert_receive {:attempt, 4}, 1_000
    assert_receive {:attempt, 5}, 1_000
    assert :atomics.get(calls, 1) == 5
    refute File.exists?(Path.join(root, "timeline.ndjson"))
  end

  test "non-GitHub trackers and missing tokens disable the production gate", %{root: root} do
    prior_path = Application.get_env(:aiur, :workflow_file_path)
    token_key = {Aiur.GitHub.Config, :resolved_token}
    prior_token = :persistent_term.get(token_key, :unset)
    :persistent_term.put(token_key, nil)

    on_exit(fn ->
      if prior_token == :unset, do: :persistent_term.erase(token_key), else: :persistent_term.put(token_key, prior_token)
      Aiur.Workflow.set_workflow_file_path(prior_path)
      Aiur.WorkflowStore.force_reload()
    end)

    for kind <- ["memory", "github"] do
      :persistent_term.put(token_key, if(kind == "memory", do: "test", else: nil))
      path = Path.join(root, "#{kind}.yaml")
      File.write!(path, "tracker:\n  kind: #{kind}\n  github:\n    repo: owner/repo\nobservability:\n  capture_github_facts: true\n")
      :ok = Aiur.Workflow.set_workflow_file_path(path)
      assert :ok = Aiur.WorkflowStore.force_reload()

      worker =
        start_supervised!(
          {RepoTimeline, name: nil, repo: "owner/repo", branch: "main", path: Path.join(root, "#{kind}.ndjson"), request_fun: fn _ -> flunk("disabled reader made a request") end, boot_capture: false},
          id: kind
        )

      assert :ok = RepoTimeline.capture(worker)
      refute File.exists?(Path.join(root, "#{kind}.ndjson"))
      assert Process.read_timer(:sys.get_state(worker).timer) > 60_000
    end
  end
end
