defmodule Aiur.Application.SupervisionContractTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Application, as: AiurApp
  alias Aiur.PubSub.Boot, as: PubSubBoot
  alias Aiur.Webhooks.{DeliveryMode, ModeTable}

  # This module's own delivery-mode key. Repository-keyed global state needs a
  # per-module key or one module's teardown erases another's fixture.
  @mode_repo "aiur-team/application-test-repo"

  describe "RunTelemetry.start_boot/0 enabled gate" do
    test "start_boot/0 writes telemetry_enabled false from config, so telemetry_enabled?/0 agrees" do
      enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
      original_pt = :persistent_term.get(enabled_key, :unset)
      original_path = Application.get_env(:aiur, :workflow_file_path)

      tmp = Aiur.TestSupport.tmp_root!("disabled-boot-test")
      config_path = Path.join(tmp, "disabledconfig.yaml")
      File.mkdir_p!(tmp)

      File.write!(config_path, """
      tracker:
        kind: github
        github:
          repo: test-org/test-repo
          label_prefix: agent
      observability:
        telemetry_enabled: false
      """)

      on_exit(fn ->
        File.rm_rf!(tmp)

        case original_path do
          nil -> Application.delete_env(:aiur, :workflow_file_path)
          value -> Application.put_env(:aiur, :workflow_file_path, value)
        end

        case original_pt do
          :unset -> :persistent_term.erase(enabled_key)
          value -> :persistent_term.put(enabled_key, value)
        end
      end)

      Application.put_env(:aiur, :workflow_file_path, config_path)
      assert Aiur.Config.telemetry_enabled?() == false

      Aiur.RunTelemetry.start_boot()

      assert Aiur.RunTelemetry.telemetry_enabled?() == false
    end
  end

  describe "shared-child supervision contract" do
    # Exercise the production strategy and child ordering without spending the
    # shared application's restart budget or killing another test's services.
    test "a crashing PubSub restarts its dependents without toppling the supervisor" do
      %{supervisor: supervisor, pubsub: pubsub, probe: probe} = isolated_shared_children()
      restarted_probe = crash_isolated_pubsub(supervisor, probe)

      assert restarted_probe != probe
      assert Process.alive?(supervisor)
      assert :ok = Phoenix.PubSub.subscribe(pubsub, "recovered")
      assert :ok = Phoenix.PubSub.broadcast(pubsub, "recovered", :pubsub_recovered)
      assert_receive :pubsub_recovered, 1000
    end

    # The two tests above build their tree through `start_supervisor/2`, not
    # the running application. This pins that `start/2` still uses it: the
    # live `Aiur.Supervisor` must run `:rest_for_one`, with its children in
    # the order that `child_specs/1` declares.
    test "the running Aiur.Supervisor uses the production strategy and child order" do
      state = :sys.get_state(Aiur.Supervisor)
      assert elem(state, 0) == :state
      assert elem(state, 2) == :rest_for_one, "Aiur.Application.start/2 no longer starts through start_supervisor/2"

      declared =
        AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)
        |> Enum.map(&(&1 |> Supervisor.child_spec([]) |> Map.fetch!(:id)))

      # `which_children/1` lists the most recently started child first.
      running = Aiur.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
      shared = Enum.filter(running, &(&1 in declared))

      assert ModeTable in shared and Phoenix.PubSub.Supervisor in shared
      assert shared == Enum.filter(declared, &(&1 in shared))
    end

    test "a crashing shared child does not erase the recorded delivery modes" do
      %{supervisor: supervisor, mode_table: mode_table, table: table, probe: probe} = isolated_shared_children()
      owner = Process.whereis(mode_table)
      mode = webhook_backed_mode()
      true = :ets.insert(table, {@mode_repo, mode})

      crash_isolated_pubsub(supervisor, probe)

      assert Process.whereis(mode_table) == owner
      assert [{@mode_repo, ^mode}] = :ets.lookup(table, @mode_repo)
      assert DeliveryMode.transport(mode) == :webhook
    end

    # The test above asserts the property. These two pin the race that decided
    # it (#2557). `Aiur.PubSub` is a partitioned `Registry`, and its partitions
    # own registered names of their own. Killing the registry kills them over
    # their links — asynchronously, whenever the scheduler next runs them —
    # while the restart above them is synchronous and retried with no backoff
    # at all. So the restart could find `Aiur.PubSub.PIDPartition0` still
    # holding its name, fail three times inside a millisecond, and take the
    # whole ~90-child tree down; whether it did was decided by scheduling
    # alone, which is why this suite passed for months and then began failing
    # when partition membership shifted the load around it.
    #
    # Holding the name with an ordinary process makes that window explicit
    # instead of hoping to land in it — and does it beside the shared tree
    # rather than inside it, so the guard cannot itself become the thing that
    # takes a partition down.
    test "the PubSub child waits for a previous incarnation's registry names" do
      name = Module.concat(__MODULE__, :"BootProbe#{System.unique_integer([:positive])}")
      held = Module.concat(name, "PIDPartition0")
      test_pid = self()

      squatter =
        spawn(fn ->
          Process.register(self(), held)
          send(test_pid, :holding)

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)

      on_exit(fn -> send(squatter, :release) end)
      assert_receive :holding, 5_000

      task = Task.async(fn -> PubSubBoot.start_link(name: name) end)

      # Nothing is started while the name is still held. The bound belongs to
      # the negative assertion; it is not a guessed recovery window.
      assert Task.yield(task, 250) == nil
      assert Process.whereis(name) == nil

      send(squatter, :release)
      assert {:ok, pid} = Task.await(task, 10_000)
      assert is_pid(pid)
    end

    test "the application starts PubSub through that child, not Phoenix.PubSub directly" do
      specs = AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)

      assert Enum.any?(specs, &match?({Aiur.PubSub.Boot, [name: Aiur.PubSub]}, &1)),
             "a bare {Phoenix.PubSub, name: Aiur.PubSub} restarts into its own dying partitions"

      assert {Aiur.PubSub.Boot, [name: Aiur.PubSub]} |> Supervisor.child_spec([]) |> Map.fetch!(:id) ==
               Phoenix.PubSub.Supervisor,
             "the child id is contract: TestSupport and SupervisionHealth address this child by it"
    end
  end

  # A proven, webhook-backed mode: configured, then proven by a delivery.
  defp webhook_backed_mode do
    {mode, :proven} = DeliveryMode.new(@mode_repo, configured?: true) |> DeliveryMode.record_delivery(~U[2026-01-01 00:00:00Z])

    mode
  end

  defp isolated_shared_children do
    suffix = System.unique_integer([:positive])
    pubsub = Module.concat(__MODULE__, "IsolatedPubSub#{suffix}")
    mode_table = Module.concat(__MODULE__, "IsolatedModeTable#{suffix}")
    table = Module.concat(__MODULE__, "IsolatedModes#{suffix}")
    parent = self()

    # Keep the order from the real child list: moving ModeTable behind PubSub
    # must erase this fixture's data too. Only the singleton names are replaced.
    children =
      AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)
      |> Enum.flat_map(fn
        ModeTable -> [{ModeTable, name: mode_table, table: table}]
        {PubSubBoot, opts} -> [{PubSubBoot, Keyword.put(opts, :name, pubsub)}]
        _child -> []
      end)

    # This dependent deliberately has no Registry link. Its restart therefore
    # proves the supervisor strategy, rather than a link-propagated exit that
    # could also restart it under :one_for_one.
    probe = %{
      id: :restart_probe,
      start:
        {Agent, :start_link,
         [
           fn ->
             :ok = Phoenix.PubSub.broadcast(pubsub, "boot", :probe_booted)
             send(parent, {:probe_started, self()})
             :ready
           end
         ]}
    }

    supervisor =
      start_supervised!(%{
        id: :isolated_shared_children,
        start: {AiurApp, :start_supervisor, [children ++ [probe]]},
        type: :supervisor
      })

    assert_receive {:probe_started, probe_pid}, 1000
    %{supervisor: supervisor, pubsub: pubsub, mode_table: mode_table, table: table, probe: probe_pid}
  end

  defp crash_isolated_pubsub(supervisor, previous_probe) do
    {Phoenix.PubSub.Supervisor, pubsub, :supervisor, _modules} =
      Enum.find(Supervisor.which_children(supervisor), fn {id, _pid, _type, _modules} ->
        id == Phoenix.PubSub.Supervisor
      end)

    monitor = Process.monitor(pubsub)
    Process.exit(pubsub, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^pubsub, :killed})
    receive_barrier({:probe_started, restarted_probe})
    assert restarted_probe != previous_probe

    # The probe reports from init; this synchronous call waits until its parent
    # has completed start_child and published the replacement in its child list.
    assert {:restart_probe, ^restarted_probe, :worker, _modules} =
             Enum.find(Supervisor.which_children(supervisor), fn {id, _pid, _type, _modules} ->
               id == :restart_probe
             end)

    restarted_probe
  end
end
