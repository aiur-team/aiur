defmodule Aiur.AAUnregisterRestoreProbeTest do
  use ExUnit.Case, async: false

  @moduletag :orchestrator_guard_probe

  # Like OperatorIdentityTest: borrows the name in setup and gives it back, never leaking.
  setup do
    original = Process.whereis(Aiur.Orchestrator)
    Process.unregister(Aiur.Orchestrator)
    on_exit(fn -> Process.register(original, Aiur.Orchestrator) end)
  end

  for n <- 1..5 do
    test "borrows the orchestrator name #{n}" do
      refute Process.whereis(Aiur.Orchestrator)
    end
  end
end

defmodule Aiur.APlainCaseWiringProbeTest do
  use ExUnit.Case, async: false

  @moduletag :orchestrator_guard_probe

  test "leaves orchestrator down" do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
  end
end

defmodule Aiur.BTestSupportWiringNeighbourTest do
  use Aiur.TestSupport, async: false

  @moduletag :orchestrator_guard_probe

  test "runs with orchestrator restored" do
    assert is_pid(Process.whereis(Aiur.Orchestrator))
  end
end

defmodule Aiur.CTestSupportWiringNextModuleTest do
  use Aiur.TestSupport, async: false

  @moduletag :orchestrator_guard_probe

  test "runs in the next module with orchestrator restored" do
    assert is_pid(Process.whereis(Aiur.Orchestrator))
  end
end

defmodule Aiur.DPlainCaseUnnamedProbeTest do
  use ExUnit.Case, async: false

  @moduletag :orchestrator_guard_probe

  # The merge-group cascade: a crashed fake's on_exit never gave the name back, so
  # the supervised child stayed alive but unnamed and restart_child refused it.
  test "leaves the supervised orchestrator unnamed" do
    Process.unregister(Aiur.Orchestrator)
  end
end

defmodule Aiur.ETestSupportReregisterNeighbourTest do
  use Aiur.TestSupport, async: false

  alias Aiur.TestSupport.OrchestratorChild

  @moduletag :orchestrator_guard_probe

  test "runs with the supervised orchestrator registered again" do
    assert Process.whereis(Aiur.Orchestrator) == OrchestratorChild.supervised_pid()
  end
end

defmodule Aiur.FPlainCasePubSubLeakProbeTest do
  use ExUnit.Case, async: false

  @moduletag :orchestrator_guard_probe

  test "leaves the PubSub registry table down" do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Phoenix.PubSub.Supervisor)
  end
end

defmodule Aiur.GTestSupportPubSubNeighbourTest do
  use Aiur.TestSupport, async: false

  alias Aiur.TestSupport.OrchestratorGuard

  @moduletag :orchestrator_guard_probe

  test "does not silently accept a prior plain-test PubSub leak" do
    assert is_pid(Process.whereis(Aiur.PubSub))

    assert_raise RuntimeError,
                 ~r/plain ExUnit tests left shared runtime children down: .*Aiur.FPlainCasePubSubLeakProbeTest: test leaves the PubSub registry table down \(Aiur.PubSub unregistered\)/,
                 fn ->
                   OrchestratorGuard.verify_suite!()
                 end
  end
end

defmodule Aiur.IPlainCaseDecisionStoreLeakProbeTest do
  use ExUnit.Case, async: false

  @moduletag :orchestrator_guard_probe

  test "leaves the durable decision store down" do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.DecisionStore)
  end
end

defmodule Aiur.JTestSupportDecisionStoreNeighbourTest do
  use Aiur.TestSupport, async: false

  alias Aiur.TestSupport.OrchestratorGuard

  @moduletag :orchestrator_guard_probe

  setup do
    on_exit(fn ->
      if is_nil(Process.whereis(Aiur.DecisionStore)) do
        assert {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, Aiur.DecisionStore)
      end
    end)
  end

  test "the guard reports which plain test left DecisionStore down" do
    assert is_nil(Process.whereis(Aiur.DecisionStore))

    assert_raise RuntimeError,
                 ~r/plain ExUnit tests left shared runtime children down: .*Aiur.IPlainCaseDecisionStoreLeakProbeTest: test leaves the durable decision store down \(Aiur.DecisionStore unregistered\)/,
                 fn -> OrchestratorGuard.verify_suite!() end
  end
end

defmodule Aiur.HTestSupportPubSubTerminationProbeTest do
  use Aiur.TestSupport, async: false

  @moduletag :orchestrator_guard_probe

  test "a real registry-table loss is restored and reported" do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Phoenix.PubSub.Supervisor)
  end
end

defmodule Aiur.YTestSupportStandInProbeTest do
  use Aiur.TestSupport, async: false

  @moduletag :orchestrator_guard_probe

  test "leaves a stand-in holding the name" do
    stand_in_state = %{
      tracker_tasks: %{},
      tick_timer_ref: nil,
      tick_token: nil,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      poll_frozen: false
    }

    {:ok, stand_in} = Agent.start(fn -> stand_in_state end)
    Process.unregister(Aiur.Orchestrator)
    Process.register(stand_in, Aiur.Orchestrator)
  end
end

defmodule Aiur.ZTestSupportWiringProbeTest do
  use Aiur.TestSupport, async: false

  @moduletag :orchestrator_guard_probe

  test "leaves orchestrator down" do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
  end
end

defmodule Aiur.ZZPlainCaseLastProbeTest do
  use ExUnit.Case, async: false

  @moduletag :orchestrator_guard_probe

  # Nothing runs after it, so only the after_suite check can catch this leak.
  test "leaves orchestrator down at suite end" do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
  end
end
