defmodule Aiur.Orchestrator.AgentTeardownTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.AgentTeardown

  test "teardown helpers tolerate absent process identifiers" do
    assert AgentTeardown.terminate_task(nil) == :ok
  end
end
