defmodule Aiur.AgentRunner.ReadMessagesBindingTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]

  test "default callback binds reads to the calling issue and supplies a deadline" do
    server = Process.whereis(Aiur.Orchestrator)
    :erlang.trace(server, true, [:receive])

    try do
      executor = Aiur.AgentRunner.ToolExecutor.build(%Aiur.Issue{id: "internal-pull-binding", identifier: "pull-binding"}, nil, nil)
      assert %{"success" => true, "output" => output} = executor.("aiur_read_messages", %{"max" => 2})
      assert Jason.decode!(output) == %{"messages" => [], "remaining" => 0}
      ref = :erlang.trace_delivered(server)
      receive_barrier({:trace_delivered, ^server, ^ref})
      assert_received {:trace, ^server, :receive, {:"$gen_call", _from, {:read_held_messages, "pull-binding", 2, deadline}}}
      assert is_integer(deadline)
    after
      :erlang.trace(server, false, [:receive])
    end
  end
end
