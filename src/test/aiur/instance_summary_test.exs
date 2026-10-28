defmodule Aiur.InstanceSummaryTest do
  use ExUnit.Case, async: true

  alias Aiur.InstanceSummary
  alias Aiur.InstanceSummary.Fact

  defp summary(providers, opts \\ []) do
    InstanceSummary.v1(Keyword.merge([instance_id: fn -> nil end, providers: providers], opts))
  end

  defp available(value), do: Fact.available(value, DateTime.utc_now() |> DateTime.to_iso8601())

  test "nil identity returns the complete value-free skeleton" do
    now = DateTime.utc_now()
    result = summary(%{}, now: now)
    assert result.instance_id == nil
    assert result.contract == "aiur.instance_summary"
    assert result.version == 1
    assert result.observed_at == DateTime.to_iso8601(now)

    for fact <- [
          result.agents.active,
          result.agents.capacity,
          result.fleet.globally_paused,
          result.commands.awaiting,
          result.commands.awaiting_blocking,
          result.executor,
          result.build_orders,
          result.background_agents,
          result.capabilities
        ] do
      assert fact.status == :unavailable
      assert fact.reason == "not_implemented"
      refute Map.has_key?(fact, :value)
    end
  end

  test "injected providers populate facts and identity" do
    result = summary(%{active: fn -> available(30) end, globally_paused: fn -> available(false) end}, instance_id: fn -> "machine/run" end)
    assert result.agents.active.value == 30
    assert result.fleet.globally_paused.value == false
    assert result.instance_id == "machine/run"
  end

  test "crash exit throw and untrappable termination yield cause-neutral unknown" do
    providers = %{
      active: fn -> raise "private diagnostic" end,
      capacity: fn -> exit(:failed) end,
      awaiting: fn -> throw(:failed) end,
      executor: fn -> Process.exit(self(), :kill) end
    }

    result = summary(providers)

    for fact <- [result.agents.active, result.agents.capacity, result.commands.awaiting, result.executor] do
      assert fact.status == :unknown
      assert fact.reason == "provider_failed"
      refute Map.has_key?(fact, :value)
    end
  end

  test "slow providers are killed within field and total budgets" do
    owner = self()

    slow = fn ->
      send(owner, {:provider, self()})

      receive do
        :finish -> available(1)
      end
    end

    for opts <- [[field_budget_ms: 20], [field_budget_ms: 300, total_budget_ms: 20]] do
      started = System.monotonic_time(:millisecond)
      result = summary(%{active: slow, capacity: slow}, opts)
      assert System.monotonic_time(:millisecond) - started < 1_600
      assert result.agents.active.status == :unknown
      assert result.agents.capacity.reason == "provider_failed"

      for _ <- 1..2 do
        assert_received {:provider, pid}
        refute Process.alive?(pid)
      end
    end
  end

  test "30 agents and 32 ordered roots fit JSON budget by retaining latest three" do
    roots = Enum.map(32..1//-1, fn n -> %{identity: String.duplicate("root ", 20) <> to_string(n), progress: n, resolution: "resolved"} end)
    result = summary(%{active: fn -> available(30) end, build_orders: fn -> available(%{count: 32, roots: roots}) end})
    assert byte_size(Jason.encode!(result)) <= 4_096
    assert result.build_orders.value.roots == Enum.take(roots, 3)
    assert result.build_orders.value.truncated == true
    assert result.build_orders.value.count == 32
  end

  test "irreducible oversize fails closed" do
    assert_raise ArgumentError, ~r/exceeds 4096/, fn -> summary(%{executor: fn -> available(%{identity: String.duplicate("executor ", 600)}) end}) end
  end

  test "nested forbidden keys are rejected and degraded values become unknown" do
    for key <- [:title, "question", "token", "unexpected"] do
      assert_raise ArgumentError, ~r/forbidden key/, fn -> summary(%{executor: fn -> available(%{consumers: [%{key => "private"}]}) end}) end
    end

    for status <- [:unavailable, :disabled, :unknown] do
      fact = summary(%{active: fn -> Fact.unavailable("offline") |> Map.merge(%{status: status, value: 0}) end}).agents.active
      assert fact.status == :unknown
      assert fact.reason == "provider_failed"
      refute Map.has_key?(fact, :value)
    end
  end

  test "golden wire fixture matches the skeleton" do
    fixture = Path.expand("../../../packages/aiur-contracts/fixtures/instance-summary.v1.json", __DIR__) |> File.read!() |> Jason.decode!()
    result = summary(%{}, now: DateTime.from_iso8601(fixture["observed_at"]) |> elem(1)) |> Jason.encode!() |> Jason.decode!()
    # Degraded facts are observed during collection; compare the injected envelope clock separately.
    strip_times = fn map -> Map.new(map, fn {key, value} -> {key, if(is_map(value), do: Map.delete(value, "observed_at"), else: value)} end) end
    for key <- ["agents", "fleet", "commands"], do: assert(strip_times.(result[key]) == strip_times.(fixture[key]))
    for key <- ["executor", "build_orders", "background_agents", "capabilities"], do: assert(Map.delete(result[key], "observed_at") == Map.delete(fixture[key], "observed_at"))
    assert Map.take(result, ["contract", "version", "instance_id", "observed_at"]) == Map.take(fixture, ["contract", "version", "instance_id", "observed_at"])
  end
end
