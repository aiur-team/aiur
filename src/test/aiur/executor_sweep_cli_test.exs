defmodule Aiur.ExecutorSweep.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.ExecutorSweep.CLI

  test "RPC entry point emits the exit marker after command output" do
    output = capture_io(fn -> CLI.rpc(snapshot: %{}) end)

    assert output =~ "Executor sweep: no findings"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert String.ends_with?(output, "__AIUR_CONTROL_EXIT__:0\n")
  end

  test "a partial sweep names every check skipped for an unavailable source" do
    output = capture_io(fn -> CLI.rpc(snapshot: %{tickets: nil, pull_requests: []}) end)

    assert output =~ "Executor sweep check unreviewed_prs skipped: tickets unavailable"
    assert output =~ "Executor sweep check ticket_hygiene skipped: tickets unavailable"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end
end
