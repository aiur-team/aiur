defmodule Aiur.BuildQueue.ClaimProbeTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildQueue.ClaimProbe

  defmodule Probe do
    @behaviour ClaimProbe
    def status(ids), do: Map.new(ids, &{&1, {:declined, :unauthorized}})

    def notify_demand(ids) do
      send(self(), {:demand, ids})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:aiur, :build_queue_claim_probe)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :build_queue_claim_probe, value)
        :error -> Application.delete_env(:aiur, :build_queue_claim_probe)
      end
    end)
  end

  test "the application wires the orchestration implementation" do
    assert ClaimProbe.impl() == Aiur.Orchestrator.BuildQueueClaimProbe
  end

  test "nil and absent implementations answer unavailable" do
    Application.put_env(:aiur, :build_queue_claim_probe, nil)
    assert ClaimProbe.status(["7"]) == :unavailable
    assert ClaimProbe.notify_demand(["7"]) == :unavailable

    Application.delete_env(:aiur, :build_queue_claim_probe)
    assert ClaimProbe.status(["7"]) == :unavailable
    assert ClaimProbe.notify_demand(["7"]) == :unavailable
  end

  test "the facade delegates both calls to the configured implementation" do
    Application.put_env(:aiur, :build_queue_claim_probe, Probe)
    assert ClaimProbe.status(["7", "8"]) == %{"7" => {:declined, :unauthorized}, "8" => {:declined, :unauthorized}}
    assert ClaimProbe.notify_demand(["7", "8"]) == :ok
    assert_received {:demand, ["7", "8"]}
  end
end
