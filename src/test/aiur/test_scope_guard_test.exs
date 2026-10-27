defmodule Aiur.TestScopeGuardTest do
  use ExUnit.Case, async: true

  test "installed module hook fails when a test leaves scope state changed" do
    {output, status} = run_probe(~S|System.put_env("AIUR_DEV_TEST_STATE_DIR", "leaked")|)

    assert status == 1, output
    assert output =~ "test scope state leaked"
  end

  test "installed module hook fails when a test leaves the financial data generation stopped" do
    start = "{:ok, _} = AiurWeb.FinancialDataAccess.Generation.start_link()"
    {output, status} = run_probe(~S|GenServer.stop(AiurWeb.FinancialDataAccess.Generation)|, start)

    assert status == 1, output
    assert output =~ "AiurWeb.FinancialDataAccess.Generation stopped"
  end

  defp run_probe(leak, start \\ ":ok") do
    guard = Path.expand("../support/test_scope_guard.exs", __DIR__)

    script = """
    Code.require_file(#{inspect(guard)})
    #{start}
    ExUnit.start()

    Code.compile_string(~S'''
    defmodule ScopeLeakProbe do
      use ExUnit.Case
      use Aiur.TestScopeGuard

      test "leaves scope state changed" do
        #{leak}
      end
    end
    ''')

    stats = ExUnit.run()
    System.halt(if(stats.failures == 1, do: 1, else: 0))
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script], stderr_to_stdout: true)
  end
end
