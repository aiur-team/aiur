defmodule Aiur.MainWatch.FixerFingerprintTest do
  use Aiur.TestSupport
  import ExUnit.CaptureLog
  alias Aiur.MainWatch.{Fixer, GitHub}

  @watch %{on_red: "dispatch_fixer", fixer_label: "main-fix"}

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    parent = self()

    opts = [
      fixer_app?: true,
      fixer_refresh: fn -> :ok end,
      fixer_open: fn _, _ -> {:ok, []} end,
      fixer_create: fn issue, _ ->
        send(parent, {:created, issue})
        {:ok, %{"number" => 7}}
      end,
      fixer_alert: fn topic, payload -> send(parent, {:alert, topic, payload}) end,
      fixer_read: fn _ -> :miss end,
      fixer_write: fn _ -> :ok end,
      fixer_snapshot: fn -> %{running: [], idle: []} end
    ]

    %{opts: opts}
  end

  test "a failed rerun polled from GitHub confirms and files a fixer", %{opts: opts} do
    run = %{
      "id" => 57,
      "head_sha" => "sha-red",
      "head_branch" => "main",
      "event" => "push",
      "name" => "ci",
      "status" => "completed",
      "conclusion" => "failure",
      "run_attempt" => 2,
      "check_suite_id" => 1,
      "created_at" => "2026-10-10T00:00:00Z",
      "updated_at" => "2026-10-10T00:10:00Z",
      "html_url" => "https://example.test/57"
    }

    check = %{"id" => 1, "name" => "test", "check_suite" => %{"id" => 1}, "app" => %{"slug" => "github-actions"}, "status" => "completed", "conclusion" => "failure"}
    request = fn %{url: url} -> evidence_response(url, run, check) end

    assert {:ok, %{observations: [observation]}} = GitHub.poll("main", ["ci"], token: "test-gh-token", request_fun: request, actions_write: false)
    assert [fingerprint] = observation.run_fingerprint
    assert tuple_size(fingerprint) == 8

    assert :ok = Fixer.reconcile([observation], @watch, opts)
    assert_received {:created, %{"title" => title}}
    assert title =~ "red at sha-red"
  end

  test "a confirmation crash degrades to unconfirmed with the error logged", %{opts: opts} do
    red = %{
      sha: String.duplicate("a", 40),
      completed_at: 1,
      run_fingerprint: :malformed,
      run_urls: ["https://github.com/run/1"],
      checks: [%{name: "test", conclusion: "failure"}],
      digest: %Aiur.CI.FailureDigest{signature: String.duplicate("b", 64), tests: :unknown}
    }

    log = capture_log(fn -> assert :ok = Fixer.reconcile([red], @watch, opts) end)
    assert log =~ "treating red as unconfirmed"
    refute_received {:created, _}
  end

  defp evidence_response(url, run, check) do
    routes = [
      {"/commits?", ok([%{"sha" => run["head_sha"]}])},
      {"event=push", ok(%{"workflow_runs" => [run]})},
      {"/actions/runs?", ok(%{"workflow_runs" => []})},
      {"/check-runs?", ok(%{"check_runs" => [check]})},
      {"/status", ok(%{"statuses" => []})},
      {"/annotations?", ok([])},
      {"/logs", ok("")},
      {"/contents/", ok(%{"encoding" => "base64", "content" => ""})},
      {"/issues?", ok([])},
      {"/pulls", ok([])}
    ]

    Enum.find_value(routes, fn {path, response} -> if String.contains?(url, path), do: response end) || flunk("unexpected request #{url}")
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
