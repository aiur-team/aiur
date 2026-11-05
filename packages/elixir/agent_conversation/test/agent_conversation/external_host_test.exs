defmodule AgentConversation.ExternalHostTest do
  @moduledoc """
  Runs `examples/standalone_host.exs` in its own BEAM.

  The example is the acceptance evidence for "an external host can mount this
  without Aiur": it builds its own scope, transport and Plug route, and it runs
  outside this test process with no host application and no credentials.
  """
  use ExUnit.Case, async: false

  @example "examples/standalone_host.exs"

  setup_all do
    {output, status} =
      System.cmd("mix", ["run", @example], cd: File.cwd!(), stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])

    %{output: output, status: status}
  end

  test "the example host renders the complete component in a plain Plug", %{output: output, status: status} do
    assert status == 0

    assert output =~ ~s(status: 200)
    assert output =~ ~s(contains data-conversation-id="game-cave": true)
    assert output =~ "contains conversation-entry: true"
    assert output =~ "contains conversation-minimap: true"
    assert output =~ "contains conversation-command-card: true"
    assert output =~ "contains conversation-composer: true"
  end

  test "the example host denies a conversation outside the authenticated scope", %{output: output} do
    assert output =~ "cross-scope status: 403 (denied: out_of_scope)"
  end
end
