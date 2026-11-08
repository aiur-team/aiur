defmodule Aiur.Gateway.StatusTest do
  use ExUnit.Case, async: false

  alias Aiur.Gateway.{Status, StatusCache, Workload}

  @nook "aaaaaaaaaaaaaaaaaaaaaaaaaa"
  @pc "bbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    dir = Path.join(System.tmp_dir!(), "gateway-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    env = [:gateway_registry_path, :remote_state_dir]
    previous = Map.new(env, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :gateway_registry_path, Path.join(dir, "remote-instances.yaml"))
    Application.put_env(:aiur, :remote_state_dir, Path.join(dir, "remote-state"))

    File.write!(
      Path.join(dir, "remote-instances.yaml"),
      "version: 1\ninstances:\n  nook:\n    url: http://nook.test:4000\n    gateway_id: \"#{@nook}\"\n  pc:\n    url: http://pc.test:4000\n    gateway_id: \"#{@pc}\"\n"
    )

    on_exit(fn ->
      for {k, v} <- previous, do: if(is_nil(v), do: Application.delete_env(:aiur, k), else: Application.put_env(:aiur, k, v))
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{now: DateTime.utc_now()}
  end

  defp agents(n), do: Jason.encode!(%{contract: "aiur.agents", contract_version: 1, running: for(i <- 1..n//1, do: %{identifier: "#{i}"})}) <> "\n__AIUR_CONTROL_EXIT__:0\n"
  defp ok(name, n), do: %{"name" => name, "status" => 0, "output" => agents(n)}
  defp down(name, status \\ 69), do: %{"name" => name, "status" => status, "output" => ""}

  defp hello(ids), do: fn url -> answer(Enum.find(ids, fn {host, _id} -> url =~ host end)) end
  defp answer({_host, id}), do: {:ok, %{"gateway_id" => id}}
  defp answer(nil), do: {:error, :timeout}
  defp both, do: hello([{"nook.test", @nook}, {"pc.test", @pc}])

  defp run(results, opts) do
    out = ExUnit.CaptureIO.capture_io(fn -> send(self(), {:code, Status.run([data: Jason.encode!(results)] ++ opts)}) end)
    assert_received {:code, code}
    {code, out}
  end

  defp seed(name, agents, now, minutes_ago) do
    :ok = StatusCache.write(name, %{observed_at: now |> DateTime.add(-minutes_ago * 60) |> DateTime.to_iso8601(), agents: agents, gateway_id: if(name == "pc", do: @pc, else: @nook)})
  end

  defp rows(out), do: out |> Jason.decode!() |> Map.fetch!("gateways") |> Map.new(&{&1["gateway"], &1})

  test "an unreachable gateway shows offline, its cached agents with their age, and never an idle workload", %{now: now} do
    seed("pc", 3, now, 12)
    {0, out} = run([ok("nook", 12), down("pc")], now: now, http_get: hello([{"nook.test", @nook}]))

    assert out =~ ~r/^pc\tyes\toffline\tunknown \(last active, 12m ago\)\t12m ago\t.*\t3 \(12m ago\)\t/m
    assert out =~ ~r/^nook\tyes\tonline\tactive\tnow\t/m
    assert out =~ "agents total: 15 (3 cached)\n"

    {0, json} = run([ok("nook", 12), down("pc")], now: now, http_get: hello([{"nook.test", @nook}]), json: true)
    pc = rows(json)["pc"]
    assert %{"connectivity" => "offline", "workload" => "unknown", "freshness" => "stale", "agents" => 3, "age_ms" => 720_000} = pc
    assert pc["last_seen_at"] == now |> DateTime.add(-720) |> DateTime.to_iso8601()
  end

  test "a 404 hello reads as error with the cause kept apart from an invalid hello", %{now: now} do
    off = fn _url -> {:error, :hello_disabled} end
    bad = fn _url -> {:error, :unrecognised} end

    {0, json} = run([ok("nook", 2)], now: now, http_get: off, peer: nil, json: true)
    assert %{"connectivity" => "error", "reason" => "hello disabled"} = rows(json)["nook"]

    {0, json} = run([ok("nook", 2)], now: now, http_get: bad, json: true)
    assert %{"connectivity" => "error", "reason" => "invalid hello"} = rows(json)["nook"]

    {0, out} = run([ok("nook", 2)], now: now, http_get: off)
    assert out =~ "error (hello disabled)"
  end

  test "a cached idle gateway that goes offline does not read as idle", %{now: now} do
    seed("pc", 0, now, 5)
    {0, json} = run([ok("nook", 1), down("pc", 124)], now: now, http_get: hello([{"nook.test", @nook}]), json: true)
    assert %{"workload" => "unknown", "last_workload" => "idle", "agents" => 0} = rows(json)["pc"]
  end

  test "an entry never reached is unknown and the total keeps the unknown", %{now: now} do
    {0, out} = run([ok("nook", 12), down("pc")], now: now, http_get: hello([{"nook.test", @nook}]))
    assert out =~ ~r/^pc\tyes\tunknown\tunknown\tnever\t.*\tunknown\t/m
    assert out =~ "agents total: 12 + unknown\n"

    {0, json} = run([ok("nook", 12), down("pc")], now: now, http_get: hello([{"nook.test", @nook}]), json: true)
    assert %{"connectivity" => "unknown", "freshness" => "none", "last_seen_at" => nil, "age_ms" => nil, "agents" => nil} = rows(json)["pc"]
    assert Jason.decode!(json)["totals"] == %{"agents" => 12, "unknown" => 1}
  end

  test "a refused peer or a different gateway id is error, not offline", %{now: now} do
    {0, json} = run([ok("nook", 2), ok("pc", 1)], now: now, http_get: hello([{"nook.test", @pc}, {"pc.test", @pc}]), json: true)
    assert %{"connectivity" => "error", "workload" => "unknown", "agents" => nil} = rows(json)["nook"]
    assert %{"connectivity" => "online"} = rows(json)["pc"]

    {0, json} = run([down("nook", 77), ok("pc", 1)], now: now, http_get: both(), json: true)
    assert %{"connectivity" => "error", "workload" => "unknown"} = rows(json)["nook"]
  end

  test "an online row carries the six documented json keys and refreshes the cache", %{now: now} do
    {0, json} = run([ok("nook", 0), ok("pc", 4)], now: now, http_get: both(), json: true)
    rows = rows(json)
    assert %{"connectivity" => "online", "workload" => "idle", "freshness" => "fresh", "age_ms" => 0, "agents" => 0} = rows["nook"]
    assert %{"workload" => "active", "last_seen_at" => _} = rows["pc"]
    for key <- ~w(gateway connectivity workload last_seen_at age_ms freshness), do: assert(Map.has_key?(rows["pc"], key))
    assert {:ok, %{agents: 4}} = StatusCache.read("pc")
  end

  test "a corrupt cache reads as never reached", %{now: now} do
    File.mkdir_p!(StatusCache.dir())
    File.write!(Path.join(StatusCache.dir(), "pc.json"), ~s({"observed_at": "not a date", "agen))
    assert StatusCache.read("pc") == :none
    {0, json} = run([ok("nook", 1), down("pc")], now: now, http_get: hello([{"nook.test", @nook}]), json: true)
    assert %{"connectivity" => "unknown", "freshness" => "none"} = rows(json)["pc"]
  end

  test "status shows one gateway in detail and rejects an unknown name", %{now: now} do
    {0, out} = run([ok("nook", 2)], now: now, http_get: both(), peer: "nook")
    assert out =~ "gateway: nook\n"
    assert out =~ "agents: 2\n"
    refute out =~ "pc"

    assert {66, out} = run([], now: now, peer: "nope")
    assert out =~ "no such gateway: nope"
  end

  test "workload is only active or idle when online" do
    assert Workload.derive("online", 2) == "active"
    assert Workload.derive("online", 0) == "idle"
    for connectivity <- ~w(offline unknown error), do: assert(Workload.derive(connectivity, 0) == "unknown")
    assert Workload.derive("online", nil) == "unknown"
  end
end
