defmodule Aiur.AgentRunner.CiWaitTransitionTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  defmodule AlertSink do
    def emit_system(topic, opts), do: send(Application.fetch_env!(:aiur, :draft_alert_test_pid), {:alert, topic, opts})
  end

  defmodule DraftCodeHostTracker do
    def code_host, do: __MODULE__
    def fetch_open_pull_request_for_branch(_), do: {:ok, nil}
  end

  test "refuses ci-wait and human-review when the ticket has an open draft PR" do
    issue = %Issue{id: "gid-te-state-draft", identifier: "4316"}
    previous_adapters = Application.fetch_env!(:aiur, :tracker_adapters)

    Application.put_env(:aiur, :tracker_adapters, %{"test" => DraftCodeHostTracker, "linear" => DraftCodeHostTracker})
    on_exit(fn -> Application.put_env(:aiur, :tracker_adapters, previous_adapters) end)

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ci_wait_pr_fetcher: fn "gid-te-state-draft" -> {:ok, %{"number" => 4318, "draft" => true}} end,
        ticket_state_writer: fn _id, _state -> flunk("draft PR must not enter a hand-off state") end
      )

    for state <- ["ci-wait", "human-review"] do
      response = executor.("aiur_set_ticket_state", %{"state" => state})
      error = Jason.decode!(response["output"])["error"]

      assert response["success"] == false
      assert error["reason"] == "draft_pr_cannot_enter_state"
      assert error["state"] == state
      assert error["pull_request"] == 4318
      assert error["message"] =~ "Mark the draft pull request ready"
    end
  end

  test "creator review handoff requires a creator Command for the current issue" do
    issue = %Issue{id: "gid-outcome-gate", identifier: "8129", labels: ["creator-facing"]}
    parent = self()

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ci_wait_pr_fetcher: fn "gid-outcome-gate" -> {:ok, nil} end,
        outcome_decisions_fun: fn -> [] end,
        ticket_state_writer: fn id, state ->
          send(parent, {:state_write, id, state})
          :ok
        end
      )

    response = executor.("aiur_set_ticket_state", %{"state" => "human-review"})

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["reason"] =~ "missing_actionable_creator_command"
    refute_received {:state_write, _, _}
  end

  test "a draft PR blocked from outside the ticket may go to human-review with its reason" do
    # A worker whose stop rule or gate is blocked from outside the ticket opens a
    # draft PR and hands it to a reviewer instead of looping into agent:error.
    # The reason is required, reaches the reviewer as an alert, and never opens
    # ci-wait, which would let the draft wait for checks as if it were done.
    issue = %Issue{id: "gid-te-state-draft-blocked", identifier: "repo#4317"}
    previous_adapters = Application.fetch_env!(:aiur, :tracker_adapters)
    previous_signal = Application.fetch_env!(:aiur, :signal)
    Application.put_env(:aiur, :signal, Keyword.put(previous_signal, :alert_sink, AlertSink))
    Application.put_env(:aiur, :draft_alert_test_pid, self())

    on_exit(fn ->
      Application.put_env(:aiur, :signal, previous_signal)
      Application.put_env(:aiur, :tracker_adapters, previous_adapters)
    end)

    Application.put_env(:aiur, :tracker_adapters, %{"test" => DraftCodeHostTracker, "linear" => DraftCodeHostTracker})
    test_pid = self()

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ci_wait_pr_fetcher: fn "gid-te-state-draft-blocked" -> {:ok, %{"number" => 4319, "draft" => true}} end,
        ticket_state_writer: fn id, state ->
          send(test_pid, {:written, id, state})
          :ok
        end
      )

    blocker = "visual gate capture times out on the shared GPU host"

    for {state, reason} <- [{"human-review", "  "}, {"ci-wait", blocker}] do
      response = executor.("aiur_set_ticket_state", %{"state" => state, "outside_blocker" => reason})
      assert Jason.decode!(response["output"])["error"]["reason"] == "draft_pr_cannot_enter_state"
    end

    refute_received {:written, _, _}

    response = executor.("aiur_set_ticket_state", %{"state" => "human-review", "outside_blocker" => blocker})

    assert response["success"] == true
    assert_received {:written, "gid-te-state-draft-blocked", "human-review"}
    assert_received {:alert, "ticket.repo#4317.agent.draft_handoff", opts}
    assert opts[:message] =~ "#4319"
    assert opts[:message] =~ blocker
  end

  describe "#8102 ci-wait requires published work" do
    setup do
      previous_adapters = Application.fetch_env!(:aiur, :tracker_adapters)
      Application.put_env(:aiur, :tracker_adapters, %{"test" => DraftCodeHostTracker, "linear" => DraftCodeHostTracker})
      on_exit(fn -> Application.put_env(:aiur, :tracker_adapters, previous_adapters) end)

      workspace = Path.join(System.tmp_dir!(), "ci-wait-transition-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
      git!(workspace, ["init", "-q"])
      git!(workspace, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"])
      %{workspace: workspace, head: String.trim(git!(workspace, ["rev-parse", "HEAD"]))}
    end

    test "refuses ci-wait with no open PR", %{workspace: workspace} do
      assert_unpublished(set_ci_wait(workspace, {:ok, nil}), "no open pull request")
    end

    test "refuses ci-wait with uncommitted work even when a PR is open", %{workspace: workspace, head: head} do
      File.write!(Path.join(workspace, "new.ex"), "untracked")
      assert_unpublished(set_ci_wait(workspace, {:ok, pr(head)}), "uncommitted or untracked")
    end

    test "refuses ci-wait when the PR head is not the local HEAD", %{workspace: workspace} do
      assert_unpublished(set_ci_wait(workspace, {:ok, pr(String.duplicate("a", 40))}), "is not the PR head")
    end

    test "allows ci-wait when the open PR head is the clean local HEAD", %{workspace: workspace, head: head} do
      response = set_ci_wait(workspace, {:ok, pr(head)}, fn _id, "ci-wait" -> :ok end)
      assert response["success"] == true
    end

    test "still allows human-review with no PR", %{workspace: workspace} do
      response = executor(workspace, {:ok, nil}, fn _id, "human-review" -> :ok end).("aiur_set_ticket_state", %{"state" => "human-review"})
      assert response["success"] == true
    end
  end

  defp pr(head), do: %{"number" => 8102, "draft" => false, "head" => %{"sha" => head}}

  defp set_ci_wait(workspace, fetched, writer \\ fn _id, _state -> flunk("unpublished work must not enter ci-wait") end),
    do: executor(workspace, fetched, writer).("aiur_set_ticket_state", %{"state" => "ci-wait"})

  defp executor(workspace, fetched, writer) do
    ToolExecutor.build(%Issue{id: "8102", identifier: "8102"}, workspace, nil, %{},
      coordination_runner: fn _key, operation, _opts -> operation.() end,
      ci_wait_pr_fetcher: fn "8102" -> fetched end,
      ticket_state_writer: writer,
      override_handoff_recorder: fn _, _, _, _, _, _ -> :ok end
    )
  end

  defp assert_unpublished(response, why) do
    error = Jason.decode!(response["output"])["error"]
    assert response["success"] == false
    assert error["reason"] == "ci_wait_work_unpublished"
    assert error["message"] =~ why
    assert error["message"] =~ "Commit, push and open the PR"
  end

  defp git!(workspace, args) do
    {out, 0} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    out
  end
end
