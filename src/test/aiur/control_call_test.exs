defmodule Aiur.ControlCallTestProbe do
  @moduledoc false

  alias Aiur.ControlCall

  def actor, do: IO.puts(ControlCall.actor())
  def read_wait, do: wait_for_test_release()
  def write_wait, do: wait_for_test_release()

  def explode do
    IO.puts("before failure")
    raise "control call probe failure"
  end

  defp wait_for_test_release do
    parent = Process.whereis(:control_call_test_parent)
    send(parent, {:control_call_probe_started, self()})

    receive do
      :finish -> send(parent, {:control_call_probe_finished, self()})
    end
  end
end

defmodule Aiur.ControlCallTest do
  use ExUnit.Case, async: false

  alias Aiur.ControlCall

  setup do
    Process.register(self(), :control_call_test_parent)
    :ok
  end

  test "parses an allowlisted literal call and refuses a foreign module" do
    assert {:ok, %{module: Aiur.AgentControlCLI, function: :agents, args: [[all: true]], scope: :read}} =
             ControlCall.parse("Aiur.AgentControlCLI.agents(all: true)")

    assert {:error, :not_allowlisted} = ControlCall.parse("System.cmd(\"id\", [])")
    assert {:error, :non_literal_argument} = ControlCall.parse(~s|Aiur.AgentControlCLI.message("1", File.read!("/etc/passwd"))|)
  end

  test "rejects executable and non-single-call syntax" do
    for {expression, reason} <- [
          {"System.cmd(\"id\", [])", :not_allowlisted},
          {":os.cmd(\"id\")", :not_allowlisted},
          {"Aiur.AgentControlCLI.status() |> System.cmd(\"id\", [])", :not_allowlisted},
          {"~s|Aiur.AgentControlCLI.status()|", :not_allowlisted},
          {"&System.cmd/2", :not_allowlisted},
          {"apply(System, :cmd, [\"id\", []])", :not_allowlisted},
          {"Aiur.AgentControlCLI.status(); System.cmd(\"id\", [])", :not_allowlisted},
          {"Aiur.AgentControlCLI.status(nested: fn -> :ok end)", :option_not_allowed},
          {"Aiur.AgentControlCLI.message(\"1\", File.read!(\"/etc/passwd\"))", :non_literal_argument},
          {"Aiur.AgentControlCLI.message(\"1\", [[[[[[[\"deep\"]]]]]]])", :non_literal_argument}
        ] do
      assert {:error, ^reason} = ControlCall.parse(expression), expression
    end
  end

  test "distinguishes unsupported options, unavailable build names and denied calls" do
    assert {:error, :option_not_allowed} = ControlCall.parse("Aiur.HarnessSessionCLI.rpc(path: \"/etc/passwd\")")
    assert {:error, :option_not_allowed} = ControlCall.parse("Aiur.AgentControlCLI.queue(server: :foo)")
    assert {:error, :option_not_allowed} = ControlCall.parse("Aiur.AgentControlCLI.analytics(telemetry_file: \"/x\")")
    assert {:error, {:unknown_on_build, "SomeModule"}} = ControlCall.parse("Aiur.AgentControlCLI.build_orders(source: SomeModule)")
    assert {:error, :option_not_allowed} = ControlCall.parse("Aiur.AgentControlCLI.build_orders(source: \"unknown\")")
    assert {:error, {:unknown_on_build, "function_from_the_future"}} = ControlCall.parse("Aiur.AgentControlCLI.function_from_the_future()")
    assert {:error, {:unknown_on_build, "future_key_qq"}} = ControlCall.parse("Aiur.AgentControlCLI.executor_wait(future_key_qq: 1)")
    assert {:error, {:unknown_on_build, "list"}} = ControlCall.parse("Aiur.AgentControlCLI.list()")
    assert {:error, {:unknown_on_build, "some_registered_name"}} = ControlCall.parse("Aiur.AgentControlCLI.usage(:some_registered_name)")
    assert {:error, :denied_remote} = ControlCall.parse(~s|Aiur.AgentControlCLI.operator_answer(decision_id: "d", operator: true, option_id: "o", expected_version: 1, confirmation: "d")|)
  end

  test "classifies mutating verbs and enforces maximum scope" do
    assert {:ok, %{scope: :write}} = ControlCall.parse("Aiur.AgentControlCLI.set_max_agents(2)")
    assert {:ok, %{scope: :write}} = ControlCall.parse("Aiur.AgentControlCLI.executor_wait(timeout_ms: 300000, json: true)")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.AgentControlCLI.executor_roster(json: true)")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.AgentControlCLI.status()")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.TicketUsageCLI.rpc(\"5692\", [])")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.AgentControlCLI.watch(mode: :full)")
    assert {:ok, %{scope: :write}} = ControlCall.parse("Aiur.AgentControlCLI.watch()")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.AgentControlCLI.queue([])")
    assert {:ok, %{scope: :read}} = ControlCall.parse("Aiur.AgentControlCLI.queue([verb: :show])")
    assert {:error, :denied_remote} = ControlCall.parse("Aiur.AgentControlCLI.queue([verb: :add, ids: [\"123\"]])")
    assert {:error, :denied_remote} = ControlCall.parse("Aiur.AgentControlCLI.queue([verb: :set])")
    assert {:error, :scope_exceeds_max} = ControlCall.parse("Aiur.AgentControlCLI.set_max_agents(2)", max_scope: :read)
  end

  test "enforces option and positional value constraints" do
    for expression <- [
          "Aiur.AgentControlCLI.set_max_agents(0)",
          "Aiur.AgentControlCLI.executor_wait(as: \"bad id\")",
          "Aiur.AgentControlCLI.executor_claim(as: \"a b\")",
          "Aiur.AgentControlCLI.message(:ok, \"text\")",
          "Aiur.AgentControlCLI.units(scope: \"invalid\")",
          "Aiur.AgentControlCLI.analytics(range: :show)",
          "Aiur.AgentControlCLI.ticket_estimate(hours: \"1000\")"
        ] do
      assert {:error, :non_literal_argument} = ControlCall.parse(expression), expression
    end

    for expression <- [
          "Aiur.AgentControlCLI.usage()",
          "Aiur.AgentControlCLI.accounts(true)"
        ] do
      assert {:error, :denied_remote} = ControlCall.parse(expression), expression
    end
  end

  test "remote calls cannot provide identity overrides or executor session env" do
    expression = ~s|Aiur.AgentControlCLI.feature(op: :create, slug: "demo", who: "operator")|
    assert {:ok, %{scope: :write}} = ControlCall.parse(expression)
    assert {:error, :option_not_allowed} = ControlCall.parse(expression, remote: true)
    assert {:error, :option_not_allowed} = ControlCall.parse(~s|Aiur.AgentControlCLI.executor_wait(env: [{"CLAUDE_PID", "12"}])|, remote: true)
  end

  test "direct actor defaults to a local identity" do
    assert ControlCall.actor() == "local:" <> (System.get_env("USER") || "unknown")
  end

  test "run captures output from an allowlisted read call" do
    assert {:ok, parsed} = ControlCall.parse("Aiur.AgentControlCLI.executor_subscriptions()")
    assert {:ok, output} = ControlCall.run(parsed, 1_000, "token:t")
    assert String.ends_with?(output, "__AIUR_CONTROL_EXIT__:0\n")
  end

  test "run captures task failures without taking down its caller" do
    assert {:ok, parsed} = ControlCall.parse("Aiur.ControlCallTestProbe.explode()")
    caller = self()
    assert {:ok, output} = ControlCall.run(parsed, 1_000, "token:t")
    assert output =~ "before failure"
    assert output =~ "__AIUR_CONTROL_ERROR__:control call probe failure"
    assert String.ends_with?(output, "__AIUR_CONTROL_EXIT__:1\n")
    assert Process.alive?(caller)
  end

  test "run stores actor in the task context" do
    assert {:ok, parsed} = ControlCall.parse("Aiur.ControlCallTestProbe.actor()")
    assert {:ok, output} = ControlCall.run(parsed, 1_000, "token:t")
    assert output =~ "token:t\n"
  end

  test "run kills a timed out read task" do
    assert {:ok, read_call} = ControlCall.parse("Aiur.ControlCallTestProbe.read_wait()")
    assert {:error, :timeout} = ControlCall.run(read_call, 500, "token:t")
    assert {:control_call_probe_started, pid} = receive_message()
    refute Process.alive?(pid)
  end

  test "run leaves a timed out write task running until completion" do
    assert {:ok, write_call} = ControlCall.parse("Aiur.ControlCallTestProbe.write_wait()")
    assert {:error, :timeout} = ControlCall.run(write_call, 500, "token:t")
    assert {:control_call_probe_started, pid} = receive_message()
    assert Process.alive?(pid)
    monitor = Process.monitor(pid)
    send(pid, :finish)
    assert {:control_call_probe_finished, ^pid} = receive_message()
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end

  defp receive_message do
    receive do
      message -> message
    after
      1_000 -> flunk("expected message from isolated caller")
    end
  end
end
