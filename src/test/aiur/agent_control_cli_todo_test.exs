defmodule Aiur.AgentControlCLITodoTest do
  # Keep the complete todo/2 contract together; these cases share only injected tracker callbacks.
  use ExUnit.Case

  import Aiur.AgentControlCLITodoSupport

  alias Aiur.Issue

  test "requests an immediate reconciliation after queueing work" do
    issues = %{"11" => %Issue{id: "node-11", identifier: "11", state: "open", labels: []}}

    {_stdout, stderr, 0} = capture_todo(["11"], deps: todo_deps(issues))

    # The queued identifiers ride along so the daemon keeps polling at the
    # base interval until it has actually seen them (#2640).
    assert_receive {:todo_request_refresh, ["11"]}, 1000
    assert stderr == ""
  end

  # A dropped wake must not be silent: the operator otherwise watches a
  # backed-off countdown that nothing shortened with no way to tell whether
  # the daemon heard them (#2640). The tracker write still succeeded, so the
  # exit code stays 0.
  test "says so when the daemon did not accept the poll refresh" do
    issues = %{"11" => %Issue{id: "node-11", identifier: "11", state: "open", labels: []}}

    {stdout, stderr, 0} = capture_todo(["11"], deps: todo_deps(issues, request_refresh_result: :unavailable))

    assert_receive {:todo_request_refresh, ["11"]}, 1000
    assert stdout =~ "queued 1 ticket(s)"
    assert stderr =~ "the daemon did not accept a poll refresh; queued tickets wait for its next scheduled poll"
  end

  # An explicit `aiur --todo` on a ticket that is already mid-flight (the
  # `agent:rework` re-queue the operator reaches for after a reviewer asks
  # for changes) keeps its label instead of adding the queue label. Before
  # this fix the refresh hint was gated on `queued > 0 or cleared > 0`, so a
  # request made up entirely of mid-flight tickets sent the daemon nothing at
  # all: no label write, no poll wake, no dispatch. The operator's explicit
  # queue was a silent no-op.
  test "requests a poll refresh for mid-flight tickets it kept" do
    issues = %{
      "138" => %Issue{id: "138", identifier: "138", state: "rework", labels: ["sym:rework"]},
      "139" => %Issue{id: "139", identifier: "139", state: "rework", labels: ["sym:rework"]}
    }

    {stdout, stderr, 0} = capture_todo(~w(138 139), deps: todo_deps(issues))

    assert_receive {:todo_request_refresh, ["138", "139"]}, 1000
    assert stdout =~ "• #138 kept sym:rework"
    assert stdout =~ "kept 2 in flight"
    assert stderr == ""
  end

  test "mutates the tracker and emits the control exit marker" do
    issue = %Issue{id: "issue-11", identifier: "11", state: "todo", title: "Queued"}

    {stdout, stderr, exit_code} =
      capture_todo(["11"],
        deps: todo_deps(%{"11" => issue}),
        emit_exit_marker: true
      )

    assert exit_code == 0
    assert stderr == ""
    assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
    assert stdout =~ "__AIUR_CONTROL_EXIT__:0"
    assert_received {:todo_add_label, "11", "sym:todo"}
  end

  test "emits a failure marker when tracker mutation fails" do
    {stdout, stderr, exit_code} =
      capture_todo(["11"],
        deps: todo_deps(%{"11" => {:error, :unavailable}}),
        emit_exit_marker: true
      )

    assert exit_code == 1
    assert stderr =~ "orchestrator unavailable"
    assert stdout =~ "queued 0 ticket(s); cleared 0 other(s)"
    assert stdout =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "reports a stopped application without a summary or stacktrace" do
    {stdout, stderr, exit_code} =
      capture_todo(["123"], deps: todo_deps(%{}, ensure_started_result: {:error, :application_not_started}))

    assert exit_code == 1
    assert stdout == ""
    assert stderr == "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry.\n"
    refute stderr =~ "GenServer"
  end

  test "queues requested tickets with config-derived labels and streaming feedback" do
    issues =
      Map.new(~w(11 12 13), fn id ->
        {id, %Issue{id: id, identifier: id, state: nil, labels: []}}
      end)

    {stdout, stderr, exit_code} = capture_todo(~w(11 12 13), deps: todo_deps(issues))

    assert exit_code == 0
    assert stderr == ""
    assert stdout =~ "✓ #11 → sym:todo"
    assert stdout =~ "✓ #12 → sym:todo"
    assert stdout =~ "✓ #13 → sym:todo"
    assert stdout =~ "queued 3 ticket(s); cleared 0 other(s)"
    assert_received {:todo_add_label, "11", "sym:todo"}
    assert_received {:todo_add_label, "12", "sym:todo"}
    assert_received {:todo_add_label, "13", "sym:todo"}
  end

  test "treats an existing todo as idempotent and preserves configured mid-flight states" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]},
      "12" => %Issue{id: "12", identifier: "12", state: "working", labels: ["sym:working"]}
    }

    {stdout, stderr, exit_code} = capture_todo(~w(11 12), deps: todo_deps(issues))

    assert exit_code == 0
    assert stderr == ""
    assert stdout =~ "✓ #11 already sym:todo"
    assert stdout =~ "• #12 kept sym:working"
    assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
    refute_received {:todo_add_label, _, _}
  end

  test "only clears custom todo labels from other pending tickets" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
    }

    active = [
      issues["11"],
      %Issue{id: "20", identifier: "20", state: "todo", labels: ["sym:todo"]},
      %Issue{id: "21", identifier: "21", state: "working", labels: ["sym:working"]},
      %Issue{id: "22", identifier: "22", state: "done", labels: ["sym:todo", "sym:done"]}
    ]

    {stdout, stderr, exit_code} =
      capture_todo(["11"], deps: todo_deps(issues, active: active), only: true)

    assert exit_code == 0
    assert stderr == ""
    assert stdout =~ "– #20 cleared sym:todo"
    assert stdout =~ "queued 1 ticket(s); cleared 1 other(s)"
    assert_received {:todo_fetch_active, ["todo", "working", "rework"]}
    assert_received {:todo_remove_label, "20", "sym:todo"}
    refute_received {:todo_remove_label, "11", _}
    refute_received {:todo_remove_label, "21", _}
    refute_received {:todo_remove_label, "22", _}
  end

  test "continues requested IDs but fails closed before only cleanup" do
    issues = %{
      "12" => {:error, :timeout},
      "13" => %Issue{id: "13", identifier: "13", state: "Closed", labels: []},
      "14" => %Issue{id: "14", identifier: "14", state: "done", labels: ["sym:done"]},
      "15" => %Issue{id: "15", identifier: "15", state: nil, labels: []}
    }

    {stdout, stderr, exit_code} =
      capture_todo(~w(11 12 13 14 15), deps: todo_deps(issues), only: true)

    assert exit_code == 1
    assert stdout =~ "✓ #15 → sym:todo"
    assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
    assert stderr =~ "✗ #11 not found"
    assert stderr =~ "✗ #12 orchestrator timed out"
    assert stderr =~ "✗ #13 terminal ticket"
    assert stderr =~ "✗ #14 terminal ticket"
    assert stderr =~ "--only cleanup skipped because 4 requested ticket(s) failed"
    assert_received {:todo_add_label, "15", "sym:todo"}
    refute_received {:todo_fetch_active, _}
  end

  test "continues requested IDs after an add failure and skips only cleanup" do
    issues =
      Map.new(~w(11 12), fn id ->
        {id, %Issue{id: id, identifier: id, state: nil, labels: []}}
      end)

    add_result = fn
      "11", "sym:todo" -> {:error, :timeout}
      _id, _label -> :ok
    end

    {stdout, stderr, exit_code} =
      capture_todo(~w(11 12), deps: todo_deps(issues, add_result: add_result), only: true)

    assert exit_code == 1
    assert stdout =~ "✓ #12 → sym:todo"
    assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
    assert stderr =~ "✗ #11 failed to add sym:todo: orchestrator timed out"
    assert stderr =~ "--only cleanup skipped because 1 requested ticket(s) failed"
    assert_received {:todo_add_label, "11", "sym:todo"}
    assert_received {:todo_add_label, "12", "sym:todo"}
    refute_received {:todo_fetch_active, _}
  end

  test "reports active-ticket enumeration failures and exits non-zero" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
    }

    {stdout, stderr, exit_code} =
      capture_todo(["11"],
        deps: todo_deps(issues, fetch_active_result: {:error, :timeout}),
        only: true
      )

    assert exit_code == 1
    assert stdout =~ "✓ #11 already sym:todo"
    assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
    assert stderr =~ "aiur: failed to enumerate active tickets (orchestrator timed out)"
    assert_received {:todo_fetch_active, ["todo", "working", "rework"]}
    refute_received {:todo_remove_label, _, _}
  end

  test "continues clearing after a removal failure and exits non-zero" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
    }

    active = [
      issues["11"],
      %Issue{id: "20", identifier: "20", state: "todo", labels: ["sym:todo"]},
      %Issue{id: "21", identifier: "21", state: "todo", labels: ["sym:todo"]}
    ]

    remove_result = fn
      "20", "sym:todo" -> {:error, :timeout}
      _id, _label -> :ok
    end

    {stdout, stderr, exit_code} =
      capture_todo(["11"], deps: todo_deps(issues, active: active, remove_result: remove_result), only: true)

    assert exit_code == 1
    assert stdout =~ "– #21 cleared sym:todo"
    assert stdout =~ "queued 1 ticket(s); cleared 1 other(s)"
    assert stderr =~ "✗ #20 failed to clear sym:todo: orchestrator timed out"
    assert_received {:todo_remove_label, "20", "sym:todo"}
    assert_received {:todo_remove_label, "21", "sym:todo"}
  end

  test "caps --only cleanup at a batch size and reports what was left untouched" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
    }

    others =
      Enum.map(21..71, fn n ->
        id = to_string(n)
        %Issue{id: id, identifier: id, state: "todo", labels: ["sym:todo"]}
      end)

    active = [issues["11"] | others]

    {stdout, stderr, exit_code} =
      capture_todo(["11"], deps: todo_deps(issues, active: active), only: true)

    assert exit_code == 0
    assert stdout =~ "queued 1 ticket(s); cleared 50 other(s)"
    assert stderr =~ "aiur: --only cleanup capped at 50 ticket(s); 1 other ticket(s) left untouched"
    assert_received {:todo_remove_label, "70", "sym:todo"}
    refute_received {:todo_remove_label, "71", "sym:todo"}
  end

  test "stops --only cleanup after repeated rate-limit failures mid-stream" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
    }

    active = [
      issues["11"],
      %Issue{id: "20", identifier: "20", state: "todo", labels: ["sym:todo"]},
      %Issue{id: "21", identifier: "21", state: "todo", labels: ["sym:todo"]},
      %Issue{id: "22", identifier: "22", state: "todo", labels: ["sym:todo"]},
      %Issue{id: "23", identifier: "23", state: "todo", labels: ["sym:todo"]}
    ]

    rate_limited = {:error, {:github, :rate_limited, %{status: 429, retry_after: 60, poll_interval: nil}}}

    remove_result = fn
      id, "sym:todo" when id in ["20", "21", "22"] -> rate_limited
      _id, _label -> :ok
    end

    {stdout, stderr, exit_code} =
      capture_todo(["11"], deps: todo_deps(issues, active: active, remove_result: remove_result), only: true)

    assert exit_code == 1
    assert stdout =~ "queued 1 ticket(s); cleared 0 other(s)"
    assert stderr =~ "aiur: --only cleanup stopped after 3 consecutive rate-limit failures"
    assert_received {:todo_remove_label, "20", "sym:todo"}
    assert_received {:todo_remove_label, "21", "sym:todo"}
    assert_received {:todo_remove_label, "22", "sym:todo"}
    refute_received {:todo_remove_label, "23", "sym:todo"}
  end

  test "stops queueing at the daemon budget and reports the tickets it never reached" do
    issues =
      Map.new(~w(11 12 13), fn id ->
        {id, %Issue{id: id, identifier: id, state: nil, labels: []}}
      end)

    {stdout, stderr, exit_code} =
      capture_todo(~w(11 12 13),
        deps: todo_deps(issues, now_ms: scripted_clock([0, 0, 0, 100])),
        budget_ms: 100,
        emit_exit_marker: true
      )

    assert exit_code == 1
    assert stdout =~ "✓ #11 → sym:todo"
    assert stdout =~ "✓ #12 → sym:todo"
    assert stdout =~ "queued 2 ticket(s); cleared 0 other(s)"
    assert stdout =~ "__AIUR_CONTROL_EXIT__:1"
    assert stderr =~ "aiur: --todo stopped after its 1s daemon budget; 1 requested ticket(s) not reached (#13)"
    assert stderr =~ "raise AIUR_CONTROL_RPC_TIMEOUT_SECONDS"
    assert_received {:todo_add_label, "11", "sym:todo"}
    assert_received {:todo_add_label, "12", "sym:todo"}
    refute_received {:todo_add_label, "13", _}
  end

  test "fails --only cleanup closed when the budget stops the queueing phase" do
    issues =
      Map.new(~w(11 12), fn id ->
        {id, %Issue{id: id, identifier: id, state: nil, labels: []}}
      end)

    {_stdout, stderr, exit_code} =
      capture_todo(~w(11 12),
        deps: todo_deps(issues, now_ms: scripted_clock([0, 0, 100])),
        budget_ms: 100,
        only: true
      )

    assert exit_code == 1
    assert stderr =~ "--only cleanup skipped because 1 requested ticket(s) failed"
    refute_received {:todo_fetch_active, _}
  end

  test "stops --only cleanup at the daemon budget and counts what it left queued" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]}
    }

    active =
      [issues["11"]] ++
        Enum.map(~w(20 21 22), fn id ->
          %Issue{id: id, identifier: id, state: "todo", labels: ["sym:todo"]}
        end)

    {stdout, stderr, exit_code} =
      capture_todo(["11"],
        deps: todo_deps(issues, active: active, now_ms: scripted_clock([0, 0, 0, 0, 0, 100])),
        budget_ms: 100,
        only: true,
        emit_exit_marker: true
      )

    assert exit_code == 1
    assert stdout =~ "– #20 cleared sym:todo"
    assert stdout =~ "– #21 cleared sym:todo"
    assert stdout =~ "queued 1 ticket(s); cleared 2 other(s)"
    assert stdout =~ "__AIUR_CONTROL_EXIT__:1"
    assert stderr =~ "aiur: --only cleanup stopped after its 1s daemon budget; 1 other ticket(s) left untouched"
    assert_received {:todo_remove_label, "20", "sym:todo"}
    assert_received {:todo_remove_label, "21", "sym:todo"}
    refute_received {:todo_remove_label, "22", _}
  end

  test "skips the active-ticket enumeration when queueing consumed the whole budget" do
    issues =
      Map.new(~w(11 12), fn id ->
        {id, %Issue{id: id, identifier: id, state: nil, labels: []}}
      end)

    {stdout, stderr, exit_code} =
      capture_todo(~w(11 12),
        deps: todo_deps(issues, now_ms: scripted_clock([0, 0, 0, 100])),
        budget_ms: 100,
        only: true
      )

    assert exit_code == 1
    assert stdout =~ "queued 2 ticket(s); cleared 0 other(s)"
    assert stderr =~ "aiur: --only cleanup skipped; the 1s daemon budget elapsed while queueing the requested tickets"
    refute_received {:todo_fetch_active, _}
    refute_received {:todo_remove_label, _, _}
  end

  test "a budget that outlasts the work changes nothing about the outcome" do
    issues = %{
      "11" => %Issue{id: "11", identifier: "11", state: "todo", labels: ["sym:todo"]},
      "12" => %Issue{id: "12", identifier: "12", state: nil, labels: []}
    }

    active = [issues["11"], issues["12"], %Issue{id: "20", identifier: "20", state: "todo", labels: ["sym:todo"]}]

    {stdout, stderr, exit_code} =
      capture_todo(~w(11 12),
        deps: todo_deps(issues, active: active, now_ms: scripted_clock([0])),
        budget_ms: 120_000,
        only: true
      )

    assert exit_code == 0
    assert stderr == ""
    assert stdout =~ "queued 2 ticket(s); cleared 1 other(s)"
    assert_received {:todo_remove_label, "20", "sym:todo"}
  end

  test "truncates a long not-reached list into one readable line" do
    ids = Enum.map(1..14, &to_string/1)
    issues = Map.new(ids, fn id -> {id, %Issue{id: id, identifier: id, state: nil, labels: []}} end)

    {_stdout, stderr, exit_code} =
      capture_todo(ids,
        deps: todo_deps(issues, now_ms: scripted_clock([0, 100])),
        budget_ms: 100
      )

    assert exit_code == 1
    assert stderr =~ "14 requested ticket(s) not reached (#1, #2, #3, #4, #5, #6, #7, #8, #9, #10, … and 4 more)"
    refute_received {:todo_add_label, _, _}
  end
end
