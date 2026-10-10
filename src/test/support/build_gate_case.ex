Code.require_file("build_gate_fixtures.ex", __DIR__)
Code.require_file("build_gate_helpers.ex", __DIR__)

defmodule Aiur.TestSupport.BuildGateCase do
  @moduledoc false
  use ExUnit.CaseTemplate, async: false

  alias Aiur.BuildGate
  import Aiur.TestSupport.BuildGateFixtures

  using do
    quote do
      alias Aiur.{AgentBuildGuard, BuildGate, PauseContainment}, warn: false
      import Aiur.TestSupport.BuildGateFixtures, warn: false
      import Aiur.TestSupport.BuildGateHelpers, warn: false

      @linux_build_gate match?({:unix, :linux}, :os.type()) and
                          not is_nil(System.find_executable("flock"))
      @linux_only if(@linux_build_gate,
                    do: [linux_lock: true],
                    else: [skip: "requires Linux flock leases"]
                  )
    end
  end

  setup do
    gate_id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-#{gate_id}")
    lock_dir = BuildGate.lock_dir(gate_dir)
    bin_dir = Path.join(gate_dir, "bin")
    log_path = Path.join(gate_dir, "mix.log")
    started_path = Path.join(gate_dir, "mix.started")
    timing_log_path = Path.join(gate_dir, "mix.timing.log")
    concurrency_path = Path.join(gate_dir, "mix.concurrency")
    max_concurrency_path = Path.join(gate_dir, "mix.max-concurrency")
    descendant_path = Path.join(gate_dir, "mix.descendant")
    descendant_release_path = Path.join(gate_dir, "mix.descendant.release")
    mix_pid_path = Path.join(gate_dir, "mix.pid")
    real_mix_project = Path.join(gate_dir, "real-mix-project")

    assert {:ok, _canonical_gate_dir} =
             BuildGate.prepare_writable_root(gate_dir: gate_dir, lock_dir: lock_dir, slots: 4)

    File.mkdir_p!(bin_dir)
    write_fake_mix!(Path.join(bin_dir, "mix"))
    write_fake_mise!(Path.join(bin_dir, "mise"))
    write_real_mix_project!(real_mix_project)

    on_exit(fn ->
      File.chmod(lock_dir, 0o755)
      File.rm_rf!(gate_dir)
      File.rm_rf!(lock_dir)
    end)

    %{
      bin_dir: bin_dir,
      gate_dir: gate_dir,
      lock_dir: lock_dir,
      log_path: log_path,
      started_path: started_path,
      timing_log_path: timing_log_path,
      concurrency_path: concurrency_path,
      max_concurrency_path: max_concurrency_path,
      descendant_path: descendant_path,
      descendant_release_path: descendant_release_path,
      mix_pid_path: mix_pid_path,
      real_mix_project: real_mix_project
    }
  end
end
