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
