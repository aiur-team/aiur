defmodule Aiur.AgentControlCLI.ReworkTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI.Rework

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

  test "a blank reason is refused before anything changes" do
    {output, calls} = run("327", "  \n ")

    assert calls == []
    assert output =~ "aiur: rework requires a nonblank --reason"
    assert output =~ "__AIUR_CONTROL_EXIT__:64"
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
