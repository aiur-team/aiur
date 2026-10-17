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
