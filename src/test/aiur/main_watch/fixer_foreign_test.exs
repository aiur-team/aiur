defmodule Aiur.MainWatch.FixerForeignTest do
  # #5803: a fixer ticket another instance owns is neither commented on,
  # recovered, nor duplicated by this instance.
  use Aiur.TestSupport
  alias Aiur.CI.FailureDigest
  alias Aiur.MainWatch.Fixer

  @watch %{on_red: "dispatch_fixer", fixer_label: "main-fix"}
  @sha String.duplicate("a", 40)
  @signature String.duplicate("b", 64)

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    store = start_supervised!({Agent, fn -> %{issues: [], comments: [], receipts: %{}} end})

    opts = [
      fixer_app?: true,
      fixer_refresh: fn -> :ok end,
      fixer_open: fn _, _ -> {:ok, Agent.get(store, & &1.issues)} end,
      fixer_create: fn body, _ ->
        body = Map.update!(body, "labels", &Enum.map(&1, fn name -> %{"name" => name} end))
        issue = Map.merge(body, %{"number" => Agent.get(store, &(length(&1.issues) + 1)), "created_at" => "2026-01-01T00:00:00Z"})
        Agent.update(store, &%{&1 | issues: &1.issues ++ [issue]})
        {:ok, issue}
      end,
      fixer_comment: fn id, body, _ -> Agent.update(store, &%{&1 | comments: &1.comments ++ [{id, body}]}) end,
      fixer_pr_open?: fn _, _ -> {:ok, true} end,
      fixer_alert: fn _topic, _payload -> :ok end,
      fixer_read: fn key -> Agent.get(store, &Map.get(&1.receipts, key, :miss)) end,
      fixer_write: fn key -> Agent.update(store, &%{&1 | receipts: Map.put(&1.receipts, key, {:ok, %{data: %{"done" => true}}})}) end,
      fixer_snapshot: fn -> %{running: [], idle: []} end,
      now_fun: fn -> 0 end
    ]

    %{store: store, opts: opts}
  end

  test "a native fixer gets the new run comment; an ignored one gets no comment, recovery or duplicate", %{store: store, opts: opts} do
    red = observation()
    assert :ok = Fixer.reconcile([red], @watch, opts)
    assert :ok = Fixer.reconcile([%{red | run_urls: ["https://github.com/run/2"]}], @watch, opts)
    assert [{"1", _body}] = Agent.get(store, & &1.comments)

    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  ignore:\n    tickets: [1]\n")
    :ok = Aiur.WorkflowStore.force_reload()

    assert :ok = Fixer.reconcile([%{red | run_urls: ["https://github.com/run/3"]}], @watch, opts)
    green = %{red | sha: String.duplicate("d", 40), checks: [%{name: "test", conclusion: "success"}]}
    assert :ok = Fixer.reconcile([green], @watch, opts)

    assert [{"1", _body}] = Agent.get(store, & &1.comments)
    assert length(Agent.get(store, & &1.issues)) == 1
  end

  defp observation do
    %{
      sha: @sha,
      completed_at: 1,
      run_fingerprint: [{"ci", 1, 2, 1, "completed", "failure", 1}],
      last_green_sha: "green",
      run_urls: ["https://github.com/run/1"],
      checks: [%{name: "test", conclusion: "failure"}],
      digest: %FailureDigest{signature: @signature, tests: [%{identity: "Example :: failure", classification: :new_failure, path: "test/example_test.exs"}]},
      suspect_merges: %{pull_requests: [%{number: 42, early: true}], complete: true}
    }
  end
end
