defmodule Aiur.ControlCall.EngineCensusTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport.EngineCase

  alias Aiur.ControlCall
  alias Aiur.ControlCall.Allowlist
  Code.require_file("../../support/executor_session_rpc_assertions.ex", __DIR__)

  @wrapper_cases [
    {"status", "cmd_status", :read, []},
    {"status handoff", "cmd_status --handoff --json", :read, []},
    {"executor session", "cmd_executor_session --json", :read, []},
    {"usage", "cmd_usage", :read, []},
    {"agents", "cmd_agents", :read, []},
    {"agents all", "cmd_agents --all", :read, []},
    {"agents json", "cmd_agents --json", :read, []},
    {"pause global", "cmd_pause_resume pause", :write, []},
    {"resume all", "cmd_pause_resume resume --all", :write, []},
    {"resume tickets", "cmd_pause_resume resume 123 456", :write, []},
    {"ownership take", "cmd_executor_ownership take 123", :write, []},
    {"ownership release", "cmd_executor_ownership release 123", :write, []},
    {"reset budget", "cmd_reset_budget 123 456", :write, []},
    {"todo", "run_todo --todo 123 456", :write, []},
    {"workspace recover", "cmd_workspace_recover ENG-123 7", :write, []},
    {"message", "cmd_message 123 hello from operator", :write, []},
    {"message with idempotency key", "cmd_message 123 --message-id msg-1 hello", :write, []},
    {"message status", "cmd_message --status 7", :read, []},
    {"set max agents", "cmd_set max-agents 5", :write, []},
    {"set runtime setting", "cmd_set agent.max_concurrent_builds 2", :write, []},
    {"unset runtime setting", "cmd_set --unset agent.max_concurrent_builds", :write, []},
    {"list runtime settings", "cmd_set --list", :read, []},
    {"list runtime settings as JSON", "cmd_set --list --json", :read, []},
    {"feature show", "cmd_feature show demo --json", :read, []},
    {"feature edit", "cmd_feature edit demo --label Demo --add-epic lane=Lane", :write, []},
    {"epic list", "cmd_epic list --json", :read, []},
    {"epic set", "cmd_epic set lane 123 --as operator", :write, []},
    {"queue show", "cmd_queue show --json", :read, []},
    {"queue order display", "cmd_queue order", :read, []},
    {"units", "cmd_units --scope all --condition active --format records --json", :read, []},
    {"build orders", "cmd_build_orders 123 --json", :read, []},
    {"analytics", "cmd_analytics --range full --since 2026-01-01 --build-order 123 --json", :read, []},
    {"GitHub cost", "cmd_github_cost --budget all --format records --json", :read, []},
    {"GitHub usage", "cmd_github_usage --json", :read, []},
    {"capabilities", "cmd_capabilities --json", :read, []},
    {"commands", "cmd_commands --filter all --blocking --ticket 123 --search x --cursor next --limit 1 --json", :read, []},
    {"alerts", "cmd_alerts --needs-attention --limit 1", :read, []},
    {"executor sweep read", "cmd_executor_sweep --json", :read, []},
    {"executor sweep apply", "cmd_executor_sweep --apply", :write, []},
    {"watch full", "cmd_watch --full", :read, []},
    {"watch changes", "cmd_watch --changes", :write, []},
    {"ticket estimate", "cmd_ticket estimate 123 0.5 --reason test --by operator --json", :write, []},
    {"ticket usage", "cmd_ticket_usage 123 --json", :read, []},
    {"experiments list", "cmd_experiments list", :read, []},
    {"experiments stats", "cmd_experiments stats 123", :read, []},
    {"experiments freeze", "cmd_experiments freeze", :write, []},
    {"executor answer", "cmd_executor_answer decision --expected-version 1 --option yes --rationale approved --idempotency-key key", :write, []},
    {"executor escalate", "cmd_executor_escalate decision --expected-version 1 --reason help", :write, []},
    {"executor reclassify", "cmd_executor_reclassify decision --expected-version 1 --rationale update", :write, []},
    {"executor moot", "cmd_executor_moot decision --expected-version 1 --reason-class obsolete", :write, []},
    {"executor wait with session env", "cmd_executor_wait --timeout 2 --as worker", :write, Aiur.TestSupport.ExecutorSessionRPCAssertions.env()},
    {"executor wait deferred acknowledgement", "cmd_executor_wait --defer-ack --ack-through 44 --json --as worker", :write, Aiur.TestSupport.ExecutorSessionRPCAssertions.env()},
    {"executor roster", "cmd_executor_roster --json", :read, []},
    {"executor fast forward", "cmd_executor_fast_forward 44 --as worker", :write, []},
    {"executor claim", "cmd_executor_claim --as worker", :write, []},
    {"executor release", "cmd_executor_release --as worker", :write, []},
    {"executor revoke", "cmd_executor_revoke worker", :write, []},
    {"executor emit", "cmd_executor_emit ticket.5965.agent.test --payload '{}'", :write, []},
    {"executor subscribe", "cmd_executor_subscription executor-subscribe ticket.5965.agent.#", :write, []},
    {"executor unsubscribe", "cmd_executor_subscription executor-unsubscribe ticket.5965.agent.#", :write, []},
    {"executor subscriptions", "cmd_executor_subscriptions", :read, []},
    {"listen validation", "cmd_listen --ticket 123", :read, []},
    {"pause all", "cmd_pause_resume pause --all", :write, []}
  ]

  @guarded_queue_commands [
    {"add", "add 123"},
    {"set", "set team --start-on default"},
    {"remove", "remove 123"},
    {"reorder", "reorder 123 --to 0"},
    {"hold", "hold 123"},
    {"release", "release 123"},
    {"recover", "recover"},
    {"clear", "clear --remove-markers --yes"},
    {"order with target", "order team --to 0"}
  ]
  @guarded_wrappers %{
    "cmd_queue" => ~s|Aiur.AgentControlCLI.queue(verb: :add, caller_agent_workspace: "")|,
    "cmd_operator_answer" => ~s|Aiur.AgentControlCLI.operator_answer(decision_id: "d", operator: true, option_id: "o", expected_version: 1, confirmation: "d")|,
    "cmd_alerts" => ~s|Aiur.AgentControlCLI.alerts(argv: ["ack", "ticket.1.agent.attention.test", "--executor-id", "operator"])|
  }

  test "every public AgentControlCLI function has an explicit classification" do
    entries = Allowlist.entries()
    missing = Enum.reject(Aiur.AgentControlCLI.__info__(:functions), &Map.has_key?(entries, {[:Aiur, :AgentControlCLI], elem(&1, 0), elem(&1, 1)}))
    assert missing == [], "unclassified public AgentControlCLI functions: #{inspect(missing)}"
  end

  test "real engine wrappers emit allowlisted expressions with their expected scope" do
    for {name, command, expected_scope, env} <- @wrapper_cases do
      expression = capture_rpc(command, env)

      result = ControlCall.parse(expression)

      assert {:ok, %{scope: ^expected_scope}} = result,
             "#{name} emitted #{expression}, parsed as #{inspect(result)}"
    end
  end

  test "real guarded queue verbs are classified as local-only" do
    source = File.read!(Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-queue.sh", __DIR__))
    assert source =~ "queue_workspace_guard"

    for {verb, arguments} <- @guarded_queue_commands do
      expression = capture_rpc("cmd_queue #{arguments}")
      result = ControlCall.parse(expression)
      assert result == {:error, :denied_remote}, "queue #{verb}: #{expression} parsed as #{inspect(result)}"
    end
  end

  test "every wrapper with an operator, TTY or agent-session guard is local-only" do
    scripts = Path.wildcard(Path.expand("../../../../packaging/npm/aiur-cli/libexec/**/*.sh", __DIR__))
    guarded = Enum.flat_map(scripts, &guarded_wrapper_names/1) |> Enum.uniq() |> Enum.sort()
    expected = Map.keys(@guarded_wrappers) |> Enum.sort()

    assert guarded == expected,
           "guarded engine wrappers changed: expected #{inspect(expected)}, found #{inspect(guarded)}"

    for {wrapper, expression} <- @guarded_wrappers do
      assert {:error, :denied_remote} = ControlCall.parse(expression),
             "#{wrapper} has a local-only guard but its RPC is not denied"
    end
  end

  test "TTY-gated operator answers remain local-only" do
    source = File.read!(Path.expand("../../../../packaging/npm/aiur-cli/libexec/engine/executor_commands.sh", __DIR__))
    assert source =~ "cmd_operator_answer()"
    assert source =~ "[ ! -t 0 ] || [ ! -t 1 ]"

    assert {:error, :denied_remote} =
             ControlCall.parse(~s|Aiur.AgentControlCLI.operator_answer_preview(decision_id: "d", operator: true, option_id: "o", expected_version: 1, confirmation: "d")|)

    assert {:error, :denied_remote} =
             ControlCall.parse(~s|Aiur.AgentControlCLI.operator_answer(decision_id: "d", operator: true, option_id: "o", expected_version: 1, confirmation: "d")|)
  end

  test "agent-only alert acknowledgements remain local-only" do
    source = File.read!(Path.expand("../../../../packaging/npm/aiur-cli/libexec/engine/report_commands.sh", __DIR__))
    assert source =~ "alerts ack is operator-only"

    assert {:error, :denied_remote} =
             ControlCall.parse(~s|Aiur.AgentControlCLI.alerts(argv: ["ack", "ticket.1.agent.attention.duplicate-dispatch", "--executor-id", "operator"])|)
  end

  test "runtime-built and non-call expressions have explicit outcomes" do
    for {expression, expected_scope} <- [
          {"Aiur.AgentControlCLI.executor_wait(timeout_ms: 300000, json: false, as: \"worker\", env: [{\"CLAUDE_CODE_SESSION_ID\", \"s-1\"}, {\"PWD\", \"/repo\"}])", :write},
          {"Aiur.AgentControlCLI.executor_fast_forward(44, [as: \"worker\"])", :write},
          {"Aiur.AgentControlCLI.executor_claim([as: \"worker\"])", :write},
          {"Aiur.AgentControlCLI.executor_release([as: \"worker\"])", :write},
          {"Aiur.AgentControlCLI.executor_revoke(\"worker\")", :write},
          {"Aiur.AgentControlCLI.executor_emit(Base.decode64!(\"dGlja2V0LjU5NjUuYWdlbnQudGVzdA==\"), Base.decode64!(\"e30=\"))", :write},
          {"Aiur.AgentControlCLI.executor_subscribe(Base.decode64!(\"dGlja2V0LjU5NjUuYWdlbnQuIw==\"))", :write},
          {"Aiur.AgentControlCLI.executor_unsubscribe(Base.decode64!(\"dGlja2V0LjU5NjUuIw==\"))", :write},
          {"Aiur.AgentControlCLI.analytics([range: :run])", :read},
          {"Aiur.AgentControlCLI.accounts(true, Base.decode64!(\"Y29kZXg=\"))", :read},
          {"Aiur.AgentControlCLI.message(\"123\", Base.decode64!(\"aGVsbG8=\"), \"msg-1\")", :write},
          {"Aiur.AgentControlCLI.todo([\"123\"], [only: true, budget_ms: 1000, emit_exit_marker: true])", :write},
          {"Aiur.AgentControlCLI.pause(:all)", :write},
          {"Aiur.AgentControlCLI.take([\"123\"], \"operator\")", :write},
          {"Aiur.AgentControlCLI.recover_workspace(Base.decode64!(\"RU5HLTEyMw==\"), 7)", :write},
          {"Aiur.AgentControlCLI.set_max_agents(2)", :write},
          {"Aiur.AgentControlCLI.usage(:codex)", :deny},
          {"Aiur.AgentControlCLI.executor_listen(topic: \"executor.#\")", :deny},
          {"Aiur.AgentControlCLI.prepare_handoff([])", :deny},
          {"Aiur.Handoff.CLI.prepare()", :deny},
          {"Aiur.PrMerge.Record.publish(\"{}\")", :deny}
        ] do
      case {ControlCall.parse(expression), expected_scope} do
        {{:ok, %{scope: scope}}, scope} when scope in [:read, :write] -> :ok
        {{:error, :denied_remote}, :deny} -> :ok
        {result, scope} -> flunk("runtime census expected #{scope} for #{expression}, got #{inspect(result)}")
      end
    end
  end

  defp capture_rpc(command, env \\ []) do
    script = """
    cd /
    run_control_rpc() { printf '%s\\n' "$1"; }
    run_control_stream() { return 0; }
    #{command}
    """

    {output, 0} =
      run_sourced_engine(script, [
        {"USER", "operator"},
        {"AIUR_AGENT_WORKSPACE", nil},
        {"AIUR_PROJECT_ROOT", nil},
        {"AIUR_REPO_ROOT", nil} | env
      ])

    output |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "Aiur."))
  end

  defp guarded_wrapper_names(path) do
    source = File.read!(path)
    functions = shell_functions(source)

    direct =
      functions
      |> Enum.filter(fn {_name, body} ->
        body =~ ~r/\[\s*!\s*-t\s+[01]\s*\]/ or
          body =~ ~r/env\s*\|\s*grep\s+-E\s+'\^\(AIUR_AGENT_/ or
          (body =~ "AIUR_AGENT_WORKSPACE" and body =~ "blocked inside agent workspaces" and body =~ "exit 64") or
          body =~ "alerts ack is operator-only"
      end)
      |> Enum.map(&elem(&1, 0))

    direct
    |> Enum.map(fn
      "queue_workspace_guard" -> "cmd_queue"
      "cmd_alerts" -> "cmd_alerts"
      "cmd_operator_answer" -> "cmd_operator_answer"
      name -> name
    end)
  end

  defp shell_functions(source) do
    declarations = Regex.scan(~r/(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{/, source, return: :index)
    offsets = Enum.map(declarations, fn [{start, _}, {name_start, name_len}] -> {start, binary_part(source, name_start, name_len)} end)

    offsets
    |> Enum.with_index()
    |> Enum.map(fn {{start, name}, index} ->
      finish =
        case Enum.at(offsets, index + 1) do
          {next, _} -> next
          nil -> byte_size(source)
        end

      {name, binary_part(source, start, finish - start)}
    end)
  end
end
