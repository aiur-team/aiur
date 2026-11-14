defmodule Aiur.AgentControlCLI.ReworkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI.Rework
  alias Aiur.ControlCall.ReplayStore

  # Open-Games #327: relabelling a ready PR's ticket to rework let a stale
  # worker turn and the CI lifecycle pull it back to ci-wait, and resume was
  # refused. The command pins rework before the reason is queued, writes the
  # label, then gives the worker a turn. It has no PR step: ready stays ready.
  test "pins rework, queues the reason, writes the label, then gives the worker a turn" do
    {output, calls} = run("327", "CI fails on the board test")

    assert [
             {:pin, "327"},
             {:send, "327", text},
             {:state, "327", "rework", [writer: :executor_rework]},
             {:resume, "327"}
           ] = calls

    assert text =~ "CI fails on the board test"
    assert text =~ "agent:rework"
    assert output =~ "aiur: ticket 327 is in agent:rework; its PR is unchanged"
    assert output =~ "aiur: resumed worker for 327"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "a working worker reads the reason at its next checkpoint" do
    {output, _calls} = run("327", "redo", resume: fn _ -> {:ok, :already_running} end)

    assert output =~ "aiur: worker for 327 is running; it reads the reason at its next checkpoint"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "a refused turn is reported after rework and the reason are recorded" do
    {output, _calls} = run("327", "redo", resume: fn _ -> {:error, :max_concurrent_agents_reached} end)

    assert output =~ "aiur: ticket 327 is in agent:rework"
    assert output =~ "no worker turn started for 327 (:max_concurrent_agents_reached)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "a failed label write stops before resuming the worker" do
    {output, calls} = run("327", "redo", state: fn _, _, _ -> {:error, :github_down} end)

    refute Enum.any?(calls, &match?({:resume, _}, &1))
    assert output =~ "aiur: rework failed for 327: could not write agent:rework (:github_down)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "a reason that cannot be queued stops before the label changes" do
    {output, calls} = run("327", "redo", send: fn _, _, _ -> {:error, :message_too_long} end)

    assert [{:pin, "327"}, {:send, "327", _text}] = calls
    assert output =~ "aiur: rework failed for 327: could not queue the reason (:message_too_long)"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  # Open-Games #330: with no live worker the send resumes one, and while the
  # ticket still said ci-wait that dispatch failed, so nothing was queued and
  # the reason never reached the worker that started a minute later.
  test "a reason whose send cannot start a worker yet is queued again once the ticket is in rework" do
    attempts = :counters.new(1, [])

    send = fn _id, _text, _opts ->
      :counters.add(attempts, 1, 1)
      if :counters.get(attempts, 1) == 1, do: {:error, {:dispatch_failed, :cause_unknown}}, else: {:ok, 13}
    end

    {output, calls} = run("330", "split the chest bug", send: send)

    assert [{:pin, "330"}, {:send, "330", _}, {:state, "330", "rework", _}, {:send, "330", _}, {:resume, "330"}] = calls
    assert output =~ "aiur: ticket 330 is in agent:rework; its PR is unchanged and the reason is queued for the worker"
    refute output =~ "rework failed"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "a blank reason is refused before anything changes" do
    {output, calls} = run("327", "  \n ")

    assert calls == []
    assert output =~ "aiur: rework requires a nonblank --reason"
    assert output =~ "__AIUR_CONTROL_EXIT__:64"
  end

  # The #768 reconciler may crash after `aiur rework --key K` and run it again.
  # The repeat must return the first receipt, also after a daemon restart, and
  # must not queue the reason or request a turn a second time.
  describe "with --key" do
    setup do
      root = Path.join(System.tmp_dir!(), "rework-key-#{System.unique_integer([:positive])}")
      previous = Application.get_env(:aiur, :control_replay_state_dir)
      Application.put_env(:aiur, :control_replay_state_dir, root)
      ReplayStore.reload()

      on_exit(fn ->
        if previous, do: Application.put_env(:aiur, :control_replay_state_dir, previous), else: Application.delete_env(:aiur, :control_replay_state_dir)
        ReplayStore.reload()
        Aiur.TestCleanup.rm_rf!(root)
      end)
    end

    test "a repeat returns the first receipt and runs nothing" do
      {first, calls} = run("768", "Round 2 needs work", key: "recon-768-r2", send: fn _, _, opts -> send(self(), {:message_id, opts[:message_id]}) && {:ok, 41} end)

      assert first =~ "the reason is queued for the worker (request 41)"
      assert first =~ "__AIUR_CONTROL_EXIT__:0"
      assert Enum.any?(calls, &match?({:resume, "768"}, &1))
      assert_received {:message_id, "rework:recon-768-r2"}

      ReplayStore.reload()
      {again, repeat_calls} = run("768", "Round 2 needs work", key: "recon-768-r2")

      assert again =~ "aiur: rework recon-768-r2 already ran for 768 (reason request 41); nothing queued again"
      assert again =~ "__AIUR_CONTROL_EXIT__:0"
      assert repeat_calls == []

      {clash, clash_calls} = run("768", "Something else", key: "recon-768-r2")
      assert clash =~ "this key was already used with different arguments"
      assert clash =~ "__AIUR_CONTROL_EXIT__:65"
      assert clash_calls == []
    end

    test "a failed first attempt runs again under the same key" do
      {failed, _calls} = run("768", "redo", key: "recon-768-r3", state: fn _, _, _ -> {:error, :github_down} end)
      assert failed =~ "__AIUR_CONTROL_EXIT__:1"

      {retried, calls} = run("768", "redo", key: "recon-768-r3")
      assert retried =~ "__AIUR_CONTROL_EXIT__:0"
      assert Enum.any?(calls, &match?({:state, "768", "rework", _}, &1))
    end
  end

  defp run(issue, reason, overrides \\ []) do
    parent = self()
    record = fn call -> send(parent, {:call, call}) end

    defaults = [
      pin: fn _id -> :ok end,
      send: fn _id, _text, _opts -> {:ok, 12} end,
      state: fn _id, _state, _opts -> :ok end,
      resume: fn _id -> {:ok, :resumed} end
    ]

    funs = Keyword.merge(defaults, overrides)

    deps = [
      key: overrides[:key],
      identifier: & &1,
      pin: fn id -> record.({:pin, id}) && funs[:pin].(id) end,
      send: fn id, text, opts -> record.({:send, id, text}) && funs[:send].(id, text, opts) end,
      state: fn id, state, opts -> record.({:state, id, state, opts}) && funs[:state].(id, state, opts) end,
      resume: fn id -> record.({:resume, id}) && funs[:resume].(id) end
    ]

    output = capture_io(fn -> Rework.rework(issue, reason, deps) end)
    {output, drain([])}
  end

  defp drain(acc) do
    receive do
      {:call, call} -> drain([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
