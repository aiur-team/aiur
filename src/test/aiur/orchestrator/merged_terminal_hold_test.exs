defmodule Aiur.Orchestrator.MergedTerminalHoldTest.Tracker do
  alias Aiur.GitHub.IssueState

  def setup(labels, request_fun, hold, attempts, now_fun) do
    :persistent_term.put({__MODULE__, :test_state}, {labels, request_fun, hold, attempts, now_fun})
  end

  def cleanup, do: :persistent_term.erase({__MODULE__, :test_state})

  def update_issue_state("3778", state_name, opts) do
    {labels, request_fun, hold, attempts, now_fun} = :persistent_term.get({__MODULE__, :test_state})

    if DateTime.compare(now_fun.(), hold.reset_at) == :lt do
      Agent.update(attempts, &(&1 + 1))
      {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}
    else
      IssueState.apply_issue_state_update(
        %{
          request_fun: request_fun,
          token: "test-token",
          owner: "owner",
          repo: "repo",
          issue_number: "3778",
          issue_url: "https://api.github.com/repos/owner/repo/issues/3778",
          prefix: "agent",
          opts: Keyword.put(opts, :request_fun, request_fun)
        },
        %{"state" => "closed", "labels" => Enum.map(Agent.get(labels, & &1), &%{"name" => &1})},
        state_name,
        "agent:#{state_name}"
      )
    end
  end
end

defmodule Aiur.Orchestrator.MergedTerminalHoldTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.MergedTerminalHoldTest.Tracker
  alias Aiur.Orchestrator.{MergeStateWriter, MergeTransition}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    :ok
  end

  test "merged terminal write waits past the local-hold ceiling until reset_at" do
    labels = start_supervised!({Agent, fn -> ["agent:parked", "agent:paused", "agent:in-progress"] end}, id: :labels)
    now = DateTime.utc_now()
    clock = start_supervised!({Agent, fn -> now end}, id: :hold_clock)
    hold_attempts = start_supervised!({Agent, fn -> 0 end}, id: :hold_attempts)
    reset_at = DateTime.add(now, 3_600_001, :millisecond)
    hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}

    request_fun = fn request ->
      case request.method do
        :get ->
          {:ok, %{status: 200, body: %{"state" => "closed", "labels" => Enum.map(Agent.get(labels, & &1), &%{"name" => &1})}}}

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

    now_fun = fn -> Agent.get(clock, & &1) end
    Tracker.setup(labels, request_fun, hold, hold_attempts, now_fun)
    on_exit(&Tracker.cleanup/0)
    parent = self()

    updater = fn identifier, target ->
      MergeStateWriter.write_if_current(identifier, target,
        fetch_issue_states_fun: fn ["3778"] -> {:ok, [%Aiur.Issue{state: "closed"}]} end,
        tracker: Tracker
      )
    end

    assert :ok =
             MergeTransition.write_terminal_target("done", "3778", updater,
               local_hold_now_fun: now_fun,
               local_hold_sleep_fun: fn wait_ms ->
                 send(parent, {:local_hold_wait, wait_ms})
                 Agent.update(clock, &DateTime.add(&1, wait_ms, :millisecond))
               end
             )

    assert_receive {:local_hold_wait, wait_ms}, 1000
    assert wait_ms > 3_600_000
    assert Agent.get(hold_attempts, & &1) == 1
    assert Agent.get(labels, & &1) == ["agent:done"]
  end
end
