defmodule Aiur.EngineCommand.RegistryTest do
  use ExUnit.Case, async: true
  import Aiur.EngineCommandTestSupport

  test "propagates a registered handler's exit status instead of treating it as an unknown command" do
    {out, 0} =
      run_sourced_engine("""
      returns_127() { return 127; }
      register_control_command returns-127 'aiur returns-127' returns_127
      code=0
      aiur_engine_main returns-127 || code=$?
      echo "CODE=$code"
      """)

    assert out =~ "CODE=127"
    refute out =~ "unknown command"
  end

  test "help renders usage registered by every shipped command fragment" do
    {out, 0} = run_sourced_engine("aiur_engine_main --help")

    assert out =~ "aiur commands [<decision-id>]"
    assert out =~ "aiur units [--scope live|unfinished|all|none]"
    assert out =~ "aiur build-orders [<root>] [--json]"
    assert out =~ "aiur analytics [--range run|full]"
  end

  test "rejects duplicate command names while loading fragments" do
    {out, 0} =
      run_sourced_engine("""
      set +e
      (register_control_command units 'aiur units' cmd_units)
      code=$?
      set -e
      echo "CODE=$code"
      """)

    assert out =~ "duplicate control command: units"
    assert out =~ "CODE=1"
  end

  test "rejects a command owned by the static dispatcher" do
    {out, 0} =
      run_sourced_engine("""
      set +e
      (register_control_command stop 'aiur stop' cmd_stop)
      code=$?
      set -e
      echo "CODE=$code"
      """)

    assert out =~ "control command is reserved: stop"
    assert out =~ "CODE=1"
  end
end
