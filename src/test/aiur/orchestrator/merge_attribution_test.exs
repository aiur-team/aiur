defmodule Aiur.Orchestrator.MergeAttributionTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{CommentWake, EventTopics, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "a sparse merged event fetches the merger and does not emit an attribution alert" do
    opts = EventTopics.pr_merged_opts(%{pr: %{"number" => 3246, "body" => "Closes #3122"}})

    request = fn req ->
      assert req.method == :get
      assert req.url == "https://api.github.com/repos/owner/repo/pulls/3246"
      assert req.caller == "merge_attribution"
      send(self(), :pr_read)
      {:ok, %{status: 200, body: %{"merged_by" => %{"login" => "its-everdred"}}}}
    end

    run_merge(opts, request)
    assert_received :pr_read
    assert_received {:allowlist, "its-everdred"}
    refute_received {:alert, _, _}
  end

  test "future regression guard: a payload merger is audited without fetching the PR" do
    opts = EventTopics.pr_merged_opts(%{pr: %{"number" => 3246, "body" => "Closes #3122", "merged_by" => %{"login" => "its-everdred"}}})
    run_merge(opts, fn _ -> flunk("attributed events must not fetch") end)
    assert_received {:allowlist, "its-everdred"}
    refute_received {:alert, _, _}
  end

  test "failed or unattributed PR reads retain the critical attribution alert" do
    for response <- [{:error, :timeout}, {:ok, %{status: 403, body: %{}}}, {:ok, %{status: 200, body: %{"merged_by" => nil}}}] do
      opts = EventTopics.pr_merged_opts(%{pr: %{"number" => 3246, "body" => "Closes #3122"}})

      run_merge(opts, fn _ ->
        send(self(), :pr_read)
        response
      end)

      assert_received :pr_read
      assert_received {:alert, "ticket.3122.merge.attribution_check_failed", alert_opts}
      assert alert_opts[:severity] == "critical"
      assert alert_opts[:needs_attention]
      refute_received {:allowlist, _}
    end
  end

  test "a fetched unauthorized merger still emits the security alert" do
    opts = EventTopics.pr_merged_opts(%{pr: %{"number" => 3246, "body" => "Closes #3122"}})
    run_merge(opts, fn _ -> {:ok, %{status: 200, body: %{"merged_by" => %{"login" => "other-user"}}}} end)
    assert_received {:allowlist, "other-user"}
    assert_received {:alert, "ticket.3122.merge.unauthorized_merger", alert_opts}
    assert alert_opts[:severity] == "critical"
  end

  defp run_merge(opts, request) do
    parent = self()

    overrides = [
      request_fun: request,
      target_state: "done",
      update_issue_state_fun: fn "3122", "done" -> :ok end,
      resume_blockees_fun: fn state, _ -> state end,
      merger_allowed_fun: fn login ->
        send(parent, {:allowlist, login})
        login == "its-everdred"
      end,
      emit_alert_fun: fn name, alert_opts -> send(parent, {:alert, name, alert_opts}) end
    ]

    CommentWake.mark_pr_merged_issue_done(%State{}, "3122", Keyword.merge(opts, overrides))
  end
end
