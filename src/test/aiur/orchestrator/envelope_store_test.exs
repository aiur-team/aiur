defmodule Aiur.Orchestrator.EnvelopeStoreTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.{EnvelopeResume, EnvelopeStore}
  alias Aiur.Config.Schema

  setup do
    path = Path.join(System.tmp_dir!(), "envelope-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :envelope_store_path)
    Application.put_env(:aiur, :envelope_store_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :envelope_store_path, previous), else: Application.delete_env(:aiur, :envelope_store_path)
      File.rm(path)
    end)

    {:ok, path: path, now: ~U[2026-10-09 12:00:00Z]}
  end

  test "round trip resumes only recent same-scheduler records", %{now: now} do
    assert EnvelopeStore.load(21_600, 16, now) == nil
    assert :ok = EnvelopeStore.save(7, 16, now)
    assert EnvelopeStore.load(21_600, 16, now) == %{safe_level: 7, resume_level: 7, recorded_at: now}
    assert EnvelopeStore.load(21_600, 16, DateTime.add(now, 21_601)) == nil
    assert EnvelopeStore.load(21_600, 8, now) == nil
    assert EnvelopeStore.load(0, 16, now) == nil
    assert EnvelopeStore.load(21_600, 16, DateTime.add(now, -1)) == nil
  end

  test "corrupt and invalid records fall back to cold start", %{path: path, now: now} do
    File.write!(path, "{")
    assert EnvelopeStore.load(21_600, 16, now) == nil

    for {key, value} <- [{"safe_level", 0}, {"safe_level", 7.0}, {"version", 2}, {"recorded_at", "bad"}] do
      record = %{"version" => 1, "safe_level" => 7, "schedulers" => 16, "recorded_at" => DateTime.to_iso8601(now)}
      Aiur.JsonStore.write!(path, Map.put(record, key, value))
      assert EnvelopeStore.load(21_600, 16, now) == nil
    end
  end

  test "boot seeds the hint and publishes once, but ignores stale and disabled records" do
    now = DateTime.utc_now()
    assert :ok = EnvelopeStore.save(7, System.schedulers_online(), now)
    agent = %Schema.Agent{}
    :ok = Aiur.Events.Exchange.subscribe("system.fleet.capacity.resume_seeded")
    boot = EnvelopeResume.boot(agent)
    receive_barrier({:event, %{topic: "system.fleet.capacity.resume_seeded", resume_level: 7, age_seconds: age}})
    assert age in 0..1
    refute_received {:event, %{topic: "system.fleet.capacity.resume_seeded"}}
    assert boot.resume_level == 7
    assert boot.recorded_at == now
    assert boot.bootstrap_complete? == false
    assert EnvelopeResume.boot(%{agent | load_resume_max_age_seconds: 0}) == %{last_decrease_ms: nil, cpu_snapshot: nil, bootstrap_complete?: false}
    assert :ok = EnvelopeStore.save(7, System.schedulers_online(), DateTime.add(now, -32_400))
    assert EnvelopeResume.boot(agent) == %{last_decrease_ms: nil, cpu_snapshot: nil, bootstrap_complete?: false}
    assert EnvelopeResume.boot(%{agent | target_load_average: nil}) == %{last_decrease_ms: nil, cpu_snapshot: nil, bootstrap_complete?: false}
    refute_received {:event, %{topic: "system.fleet.capacity.resume_seeded"}}
  end

  test "schema exposes the default and rejects negative resume lifetime" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.load_resume_max_age_seconds == 21_600
    assert {:ok, disabled} = Schema.parse(%{"agent" => %{"load_resume_max_age_seconds" => 0}})
    assert disabled.agent.load_resume_max_age_seconds == 0
    assert {:error, _reason} = Schema.parse(%{"agent" => %{"load_resume_max_age_seconds" => -1}})
  end

  test "write failure returns an error", %{path: path, now: now} do
    File.mkdir_p!(path)
    on_exit(fn -> File.rmdir(path) end)
    assert {:error, {:write_failed, MatchError}} = EnvelopeStore.save(7, 16, now)
  end
end
