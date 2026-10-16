defmodule Aiur.TestScopeGuardTest do
  use ExUnit.Case, async: true

  test "installed module hook fails when a test leaves scope state changed" do
    {output, status} = run_probe(~S|System.put_env("AIUR_DEV_TEST_TICKET_IDS", "leaked")|)

    assert status == 1, output
    assert output =~ "test scope state leaked"
  end

  test "installed module hook fails when a test leaves Stream Deck auth config changed" do
    {output, status} =
      run_probe(~S|Application.put_env(:aiur, AiurWeb.Endpoint, secret_key_base: "leaked", dashboard_auth_required: true)|)

    assert status == 1, output
    assert output =~ "AiurWeb.Endpoint auth"
    assert output =~ ~s(secret_key_base: {:ok, "leaked"})
  end

  defp run_probe(leak) do
    guard = Path.expand("../support/test_scope_guard.exs", __DIR__)

    script = """
    Code.require_file(#{inspect(guard)})
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

    System.cmd("elixir", ["-e", script], stderr_to_stdout: true)
  end
end
