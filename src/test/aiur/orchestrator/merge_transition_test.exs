defmodule Aiur.Orchestrator.MergeTransitionTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.Orchestrator.{CommentWake, MergeStateWriter, MergeTransition, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    :ok
  end

  test "GitHub closing keyword before the merge write completes an already done ticket without an alert" do
    issue = %{
      "state" => "closed",
      "labels" => [%{"name" => "agent:done"}, %{"name" => "agent:queued"}],
      "body" => "private issue body"
    }

    parent = self()

    log =
      capture_log(fn ->
        merge(issue, fn state, identifier ->
          send(parent, {:resumed, identifier})
          state
        end)
      end)

    assert_received {:resumed, "3778"}
    assert_received :terminated
    refute log =~ "merge_terminal_write_failed"
    refute log =~ "private issue body"
  end

  test "operator hold labels follow the configured agent prefix" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    assert MergeStateWriter.operator_hold_labels() == ["needs-triage", "human:todo", "sym:paused", "sym:parked"]
  end

  test "a closed ticket with an active label is repaired to done" do
    issue = %{
      "state" => "closed",
      "labels" => [%{"name" => "agent:rework"}],
      "body" => String.duplicate("private issue body", 500)
    }

    log = capture_log(fn -> merge(issue) end)
    assert_received :terminated
    refute log =~ "ticket.3778.agent.attention.merge_terminal_write_failed"
    refute log =~ "no_state_label_written"
    refute log =~ "private issue body"
    refute log =~ "ticket was not closed"
  end

  test "future regression guard: only closed issues with only the done state label satisfy the merge" do
    for {state, labels} <- [
          {"open", ["agent:done"]},
          {"closed", []},
          {"closed", ["agent:cancelled"]},
          {"closed", ["agent:done", "agent:rework"]},
          {"closed", ["other:done"]}
        ] do
      outcome =
        {"rework", {:error, {:no_state_label_written, %{"state" => state, "labels" => Enum.map(labels, &%{"name" => &1})}}}}

      assert MergeTransition.normalize(outcome) == outcome
    end
  end

  test "future regression guard: other failures retain their outcome and have bounded cause names" do
    assert MergeTransition.normalize({"done", {:error, :timeout}}) == {"done", {:error, :timeout}}
    assert MergeTransition.reason_name(:timeout) == :timeout
    assert MergeTransition.reason_name({:github, :permission, %{status: 403}}) == :permission
    assert MergeTransition.reason_name({:github, :local_hold, %{body: "private"}}) == :local_hold
    assert MergeTransition.reason_name(%{body: "private"}) == :unknown
  end

  test "transient terminal label failure retries and completes the merged ticket" do
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :attempts)
    labels = start_supervised!({Agent, fn -> ["agent:in-progress"] end}, id: :labels)
    parent = self()

    request_fun = fn request ->
      case request.method do
        :get ->
          {:ok,
           %{
             status: 200,
             body: %{
               "state" => "closed",
               "labels" => Enum.map(Agent.get(labels, & &1), &%{"name" => &1})
             }
           }}

        :post ->
          first_attempt? = Agent.get_and_update(attempts, fn n -> {n == 0, n + 1} end)

          if first_attempt? do
            {:error, :timeout}
          else
            Agent.update(labels, &Enum.uniq(&1 ++ request.body["labels"]))
            {:ok, %{status: 200, body: Enum.map(Agent.get(labels, & &1), &%{"name" => &1})}}
          end

        :delete ->
          removed = URI.decode(request.url |> String.split("/") |> List.last())
          Agent.update(labels, &Enum.reject(&1, fn label -> label == removed end))
          {:ok, %{status: 200, body: Enum.map(Agent.get(labels, & &1), &%{"name" => &1})}}

        :patch ->
          {:ok, %{status: 200, body: %{}}}
      end
    end

    context = %{
      request_fun: request_fun,
      token: "test-token",
      owner: "owner",
      repo: "repo",
      issue_number: "3778",
      issue_url: "https://api.github.com/repos/owner/repo/issues/3778",
      prefix: "agent",
      opts: [request_fun: request_fun]
    }

    updater = fn "3778", "done" ->
      result =
        IssueState.apply_issue_state_update(
          context,
          %{
            "state" => "closed",
            "labels" => Enum.map(Agent.get(labels, & &1), &%{"name" => &1})
          },
          "done",
          "agent:done"
        )

      send(parent, {:write_result, result})
      result
    end

    merge(
      %{"state" => "closed", "labels" => [%{"name" => "agent:done"}]},
      fn state, _id -> state end,
      target_state: "done",
      update_issue_state_fun: updater,
      merge_terminal_write_sleep_fun: fn _ -> :ok end
    )

    assert_receive :terminated, 1_000
    assert_receive {:write_result, :ok}, 1_000
    assert Agent.get(attempts, & &1) == 2
    assert Agent.get(labels, & &1) == ["agent:done"]
  end

  test "local hold and rate limit are left to the request boundary wait" do
    for reason <- [
          {:github, :local_hold, %{reset_at: 123}},
          {:github, :rate_limited, %{retry_after: 1}}
        ] do
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      updater = fn _id, _target ->
        Agent.update(attempts, &(&1 + 1))
        {:error, reason}
      end

      result =
        MergeTransition.retry_terminal_write(fn -> updater.("3778", "done") end,
          merge_terminal_write_sleep_fun: fn _ ->
            flunk("must not inner-retry request-boundary holds")
          end
        )

      assert result == {:error, reason}
      assert Agent.get(attempts, & &1) == 1
    end
  end

  test "a no-body duplicate merge wake preserves done after the first closing wake fails" do
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :attempts)
    labels = start_supervised!({Agent, fn -> ["agent:in-progress"] end}, id: :labels)

    request_fun = fn request ->
      case request.method do
        :get ->
          if String.contains?(request.url, "/pulls?") do
            {:ok, %{status: 200, body: []}}
          else
            {:ok, %{status: 200, body: %{"state" => "closed", "labels" => Enum.map(Agent.get(labels, & &1), &%{"name" => &1})}}}
          end

        :post ->
          Agent.update(labels, &Enum.uniq(&1 ++ request.body["labels"]))
          {:ok, %{status: 200, body: Enum.map(Agent.get(labels, & &1), &%{"name" => &1})}}

        :delete ->
          removed = URI.decode(request.url |> String.split("/") |> List.last())
          Agent.update(labels, &Enum.reject(&1, fn label -> label == removed end))
          {:ok, %{status: 200, body: Enum.map(Agent.get(labels, & &1), &%{"name" => &1})}}

        :patch ->
          {:ok, %{status: 200, body: %{}}}
      end
    end

    context = %{
      request_fun: request_fun,
      token: "test-token",
      owner: "owner",
      repo: "repo",
      issue_number: "3778",
      issue_url: "https://api.github.com/repos/owner/repo/issues/3778",
      prefix: "agent",
      opts: [request_fun: request_fun]
    }

    parent = self()

    updater = fn "3778", target ->
      if Agent.get_and_update(attempts, fn count -> {count == 0, count + 1} end) do
        send(parent, {:merge_write_attempt, 1})
        {:error, {:github, :github_issue_response_too_large, %{}}}
      else
        result =
          IssueState.apply_issue_state_update(
            context,
            %{"state" => "closed", "labels" => Enum.map(Agent.get(labels, & &1), &%{"name" => &1})},
            target,
            "agent:#{target}"
          )

        send(parent, {:merge_write_attempt, 2, result})
        result
      end
    end

    merge(%{"state" => "closed", "labels" => [%{"name" => "agent:in-progress"}]}, fn state, _ -> state end,
      target_state: "done",
      update_issue_state_fun: updater,
      merge_terminal_write_sleep_fun: fn _ -> :ok end
    )

    assert_received {:merge_write_attempt, 1}

    merge(%{"state" => "closed", "labels" => [%{"name" => "agent:in-progress"}]}, fn state, _ -> state end,
      pr_body: nil,
      update_issue_state_fun: updater,
      open_pull_requests_fun: fn _ -> {:ok, []} end
    )

    assert_receive {:merge_write_attempt, 2, _result}, 1_000
    assert Agent.get(labels, & &1) == ["agent:done"]
    assert Agent.get(attempts, & &1) == 2
  end

  test "transient non-terminal merge target failure is retried" do
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :attempts)
    parent = self()

    updater = fn "3778", "human-review" ->
      result =
        Agent.get_and_update(attempts, fn count ->
          next = count + 1
          {if(next == 1, do: {:error, {:github, :timeout, %{reason: :timeout}}}, else: :ok), next}
        end)

      send(parent, {:human_review_write, result})
      result
    end

    merge(
      %{"state" => "open", "labels" => [%{"name" => "agent:in-progress"}]},
      fn state, _id -> state end,
      target_state: "human-review",
      update_issue_state_fun: updater,
      merge_terminal_write_sleep_fun: fn _ -> :ok end
    )

    assert_receive {:human_review_write, :ok}, 1_000
    assert Agent.get(attempts, & &1) == 2
  end

  test "terminal write alert reports the GitHub classification" do
    log =
      capture_log(fn ->
        merge(
          %{"state" => "closed", "labels" => []},
          fn state, _id -> state end,
          update_issue_state_fun: fn _id, _target ->
            {:error, {:github, :permission, %{status: 403}}}
          end,
          merge_terminal_write_sleep_fun: fn _ -> :ok end
        )
      end)

    assert log =~ "merge_terminal_write_failed"
    assert log =~ "reason=permission"
  end

  test "transient terminal write retries stop at the configured attempt limit" do
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :attempts)
    parent = self()

    updater = fn _id, _target ->
      next = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(parent, {:write_attempt, next})
      {:error, {:github, :timeout, %{reason: :timeout}}}
    end

    log =
      capture_log(fn ->
        merge(
          %{"state" => "closed", "labels" => []},
          fn state, _id -> state end,
          target_state: "done",
          update_issue_state_fun: updater,
          merge_terminal_write_sleep_fun: fn delay -> send(parent, {:retry_delay, delay}) end
        )
      end)

    assert Agent.get(attempts, & &1) == 3
    assert_receive {:write_attempt, 1}, 1_000
    assert_receive {:write_attempt, 2}, 1_000
    assert_receive {:write_attempt, 3}, 1_000
    assert_receive {:retry_delay, 100}, 1_000
    assert_receive {:retry_delay, 200}, 1_000
    refute_receive {:retry_delay, _}, 50
    refute_receive :terminated, 50
    assert log =~ "reason=timeout"
  end

  defp merge(issue, resume \\ fn state, _identifier -> state end, opts \\ []) do
    request_fun = fn request ->
      case request.method do
        :get -> {:ok, %{status: 200, body: issue}}
        :delete -> {:ok, %{status: 200, body: []}}
        :post -> {:ok, %{status: 200, body: []}}
        other -> flunk("unexpected write: #{other}")
      end
    end

    context = %{
      request_fun: request_fun,
      token: "test-token",
      owner: "owner",
      repo: "repo",
      issue_number: "3778",
      issue_url: "https://api.github.com/repos/owner/repo/issues/3778",
      prefix: "agent",
      opts: [request_fun: request_fun]
    }

    parent = self()
    ticket = %Aiur.Issue{id: "3778", identifier: "3778", state: "rework"}

    state = %State{
      running: %{"3778" => %{issue: ticket, identifier: "3778"}},
      completed: MapSet.new(),
      claimed: MapSet.new(["3778"])
    }

    CommentWake.mark_pr_merged_issue_done(state, "3778",
      pr_body: Keyword.get(opts, :pr_body, "Closes #3778"),
      target_state: Keyword.get(opts, :target_state),
      open_pull_requests_fun:
        Keyword.get(opts, :open_pull_requests_fun, fn _identifier ->
          {:ok, [%{"number" => 3779, "review_decision" => "CHANGES_REQUESTED"}]}
        end),
      unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "remaining-thread"}]} end,
      update_issue_state_fun:
        Keyword.get(opts, :update_issue_state_fun, fn "3778", target ->
          IssueState.apply_issue_state_update(context, issue, target, "agent:#{target}")
        end),
      merger_allowed_fun: fn _login -> true end,
      clear_session_handle_fun: fn "3778" -> :ok end,
      terminate_running_issue_fun: fn current, "3778", true ->
        send(parent, :terminated)
        current
      end,
      observe_membership_fun: fn _identity, _lifecycle -> :ok end,
      mark_reconciled_fun: fn _identifier -> :ok end,
      set_terminal_verification_pending_fun: fn _identity, _pending -> :ok end,
      resume_blockees_fun: resume,
      merge_terminal_write_sleep_fun: Keyword.get(opts, :merge_terminal_write_sleep_fun, fn _ -> :ok end)
    )
  end
end
