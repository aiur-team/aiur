defmodule Aiur.TestScopeGuardTest do
  use ExUnit.Case, async: true

  test "installed module hook fails when a test leaves scope state changed" do
    guard = Path.expand("../support/test_scope_guard.exs", __DIR__)

    script = """
    Code.require_file(#{inspect(guard)})
    ExUnit.start()

    Code.compile_string(\"\"\"
    defmodule ScopeLeakProbe do
      use ExUnit.Case
      use Aiur.TestScopeGuard

      test \"leaves an environment value changed\" do
        System.put_env(\"AIUR_DEV_TEST_TICKET_IDS\", \"leaked\")
      end
    end
    \"\"\")

    stats = ExUnit.run()
    System.halt(if(stats.failures == 1, do: 1, else: 0))
    """

    {output, status} = System.cmd("elixir", ["-e", script], stderr_to_stdout: true)

    assert status == 1, output
    assert output =~ "test scope state leaked"
  end
end
