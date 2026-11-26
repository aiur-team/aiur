defmodule Aiur.Config.CapacityPolicyTest do
  use Aiur.TestSupport

  alias Aiur.Config.CapacityPolicy
  alias Aiur.Config.CapacityPolicy.TightenCheck
  alias Aiur.Config.{Overrides, Provenance, Schema, SemanticChecks}
  alias Aiur.Machine.Settings

  setup do
    home = Path.join(System.tmp_dir!(), "capacity-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    machine = Path.join(home, "machine")
    previous_machine = Application.get_env(:aiur, :machine_settings_path)
    previous_instance = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :machine_settings_path, machine)
    System.put_env("AIUR_INSTANCE_KEY", "capacity-policy-#{System.unique_integer([:positive])}")
    {:ok, override_path} = Overrides.path()

    on_exit(fn ->
      if previous_machine, do: Application.put_env(:aiur, :machine_settings_path, previous_machine), else: Application.delete_env(:aiur, :machine_settings_path)
      if previous_instance, do: System.put_env("AIUR_INSTANCE_KEY", previous_instance), else: System.delete_env("AIUR_INSTANCE_KEY")
      :persistent_term.erase({Settings, machine})
      Aiur.TestCleanup.rm_rf!(home)
      Aiur.TestCleanup.rm_rf!(Path.dirname(override_path))
    end)

    %{machine: machine}
  end

  @machine_yaml """
  capacity:
    sources:
      claude: { billing: subscription, reserve: { percent: 30, accounts: [default] } }
      openrouter: { billing: prepaid, last_resort: true, limits: { daily_usd: 5, monthly_usd: 40 } }
    limits: { weekly_usd: 20 }
    default_burn_percent_per_hour: 4
  """

  defp machine!(path, yaml) do
    File.write!(path, yaml)
    {:ok, settings} = Settings.load()
    settings
  end

  defp project!(capacity) do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "capacity" => capacity})
    settings
  end

  test "with no capacity block the effective policy allows everything", %{machine: machine} do
    {:ok, settings} = Settings.load()
    refute File.exists?(machine)

    assert {:ok, policy} = CapacityPolicy.effective(settings.capacity, %Schema{}.capacity)
    assert policy.sources == %{}
    assert policy.limits == %{daily_usd: nil, weekly_usd: nil, monthly_usd: nil}
    assert policy.default_burn_percent_per_hour == nil

    for backend <- ~w(claude codex openrouter) do
      source = CapacityPolicy.source(policy, backend)
      assert source.reserve == %{percent: 0, accounts: :all}
      refute source.last_resort
      assert source.limits == %{daily_usd: nil, weekly_usd: nil, monthly_usd: nil}
      assert source.serves == ["coding"]
    end
  end

  test "machine keys parse and project values only tighten the merged policy", %{machine: machine} do
    settings = machine!(machine, @machine_yaml)

    project =
      project!(%{
        "sources" => %{
          "claude" => %{"reserve" => %{"percent" => 40}},
          "openrouter" => %{"limits" => %{"daily_usd" => 2}},
          "codex" => %{"last_resort" => true}
        },
        "limits" => %{"weekly_usd" => 10, "daily_usd" => 3}
      })

    assert :ok = TightenCheck.check(project)
    assert {:ok, policy} = CapacityPolicy.effective(settings.capacity, project.capacity)

    assert %{billing: "subscription", reserve: %{percent: 40, accounts: ["default"]}, last_resort: false} = policy.sources["claude"]
    assert %{billing: "prepaid", last_resort: true, limits: %{daily_usd: 2, monthly_usd: 40, weekly_usd: nil}} = policy.sources["openrouter"]
    assert %{billing: "unknown", last_resort: true} = policy.sources["codex"]
    assert policy.limits == %{daily_usd: 3, weekly_usd: 10, monthly_usd: nil}
    assert policy.default_burn_percent_per_hour == 4.0
  end

  test "a project value that loosens a machine value is refused and names both layers", %{machine: machine} do
    machine!(machine, @machine_yaml)

    for {capacity, key} <- [
          {%{"sources" => %{"openrouter" => %{"limits" => %{"daily_usd" => 6}}}}, "capacity.sources.openrouter.limits.daily_usd"},
          {%{"sources" => %{"claude" => %{"reserve" => %{"percent" => 10}}}}, "capacity.sources.claude.reserve.percent"},
          {%{"sources" => %{"openrouter" => %{"last_resort" => false}}}, "capacity.sources.openrouter.last_resort"},
          {%{"limits" => %{"weekly_usd" => 25}}, "capacity.limits.weekly_usd"}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = TightenCheck.check(project!(capacity))
      assert message =~ key
      assert message =~ "project (L3)"
      assert message =~ "machine (L1)"
    end
  end

  test "the registered semantic checks refuse a loosening project config on the real load path", %{machine: machine} do
    machine!(machine, @machine_yaml)
    config = %{"tracker" => %{"kind" => "memory"}, "capacity" => %{"limits" => %{"weekly_usd" => 25}}}

    assert {:ok, settings} = Aiur.Config.settings_from({:ok, %{config: config}})
    assert {:error, {:invalid_workflow_config, message}} = SemanticChecks.validate(settings)
    assert message =~ "capacity.limits.weekly_usd"
    assert message =~ "project (L3)"
    assert message =~ "machine (L1)"
  end

  test "machine-owned keys are rejected in a project config and bad machine values are rejected", %{machine: machine} do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "capacity" => %{"sources" => %{"claude" => %{"billing" => "metered"}}}})

    assert message =~ "claude.billing is machine-owned"

    for {capacity, expected} <- [
          {%{"limit" => %{"daily_usd" => 5}}, "limit is an unknown key"},
          {%{"default_burn_percent_per_hour" => 3}, "default_burn_percent_per_hour is machine-owned; set it in ~/.aiur/machine"},
          {%{"max_agents" => 2}, "max_agents is machine-owned; set it in ~/.aiur/machine"}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "capacity" => capacity})
      assert message =~ expected
    end

    File.write!(machine, "capacity:\n  sources:\n    claude: { billing: free, reserve: { percent: 120 } }\n")
    assert {:error, {:invalid, errors}} = Settings.load()
    assert {"capacity.sources", "claude.billing must be one of subscription, prepaid, metered, unknown"} in errors
    assert {"capacity.sources", "claude.reserve.percent must be a number from 0 to 100"} in errors
  end

  test "aiur set may raise a reserve but a lower value is refused naming the runtime layer", %{machine: machine} do
    machine!(machine, @machine_yaml)

    assert {:error, {:invalid_workflow_config, message}} = Overrides.set("capacity.sources.claude.reserve.percent", 20, "local:test")
    assert message =~ "runtime (L5) value 20 loosens the machine (L1) value 30"

    assert {:ok, %{key: "capacity.sources.claude.reserve.percent", value: 50}} =
             Overrides.set("capacity.sources.claude.reserve.percent", 50, "local:test")

    assert {:ok, settings} = Aiur.Config.settings_uncached()
    assert {:ok, policy} = CapacityPolicy.effective(Settings.get() |> elem(1) |> Map.fetch!(:capacity), settings.capacity)
    assert policy.sources["claude"].reserve.percent == 50
  end

  test "an aiur set reserve below the project reserve is refused naming the project layer" do
    config = %{"capacity" => %{"sources" => %{"codex" => %{"reserve" => %{"percent" => 15}}}}}
    machine_fun = fn -> {:ok, %Settings{}} end

    assert {:error, {:invalid_workflow_config, message}} = CapacityPolicy.check_runtime("capacity.sources.codex.reserve.percent", 10, config, machine_fun)
    assert message =~ "loosens the project (L3) value 15"
    assert :ok = CapacityPolicy.check_runtime("capacity.sources.codex.reserve.percent", 15, config, machine_fun)
  end

  test "config explain names the layer of the tightest value", %{machine: machine} do
    settings = machine!(machine, @machine_yaml)
    project = "/repo/.aiur/config"

    opts = [
      candidates: [project, "/home/u/.aiur/config"],
      machine_fun: fn -> {:ok, settings} end,
      overrides_fun: fn -> {:ok, [%{key: "capacity.sources.claude.reserve.percent", value: 45}]} end,
      load_fun: fn
        ^project -> {:ok, %{"capacity" => %{"sources" => %{"claude" => %{"reserve" => %{"percent" => 35}}, "openrouter" => %{"limits" => %{"daily_usd" => 7}}}}}}
        _ -> :missing
      end
    ]

    assert {:ok, %{value: 45, layer: "L5", overridden: overridden}} = Provenance.explain("capacity.sources.claude.reserve.percent", opts)
    assert Enum.map(overridden, &{&1.layer, &1.value}) == [{"L3", 35}, {"L1", 30}]

    assert {:ok, %{value: 5, layer: "L1", overridden: [%{layer: "L3", value: 7}]}} =
             Provenance.explain("capacity.sources.openrouter.limits.daily_usd", opts)

    assert {:ok, %{value: "prepaid", layer: "L1"}} = Provenance.explain("capacity.sources.openrouter.billing", opts)
    assert {:ok, %{value: "unknown", layer: "L0"}} = Provenance.explain("capacity.sources.codex.billing", opts)
    assert {:ok, %{value: 4.0, layer: "L1"}} = Provenance.explain("capacity.default_burn_percent_per_hour", opts)
    assert {:error, {:unknown_key, _, _}} = Provenance.explain("capacity.sources.codex.colour", opts)
  end
end
