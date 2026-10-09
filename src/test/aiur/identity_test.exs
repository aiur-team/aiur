defmodule Aiur.IdentityTest do
  use ExUnit.Case, async: false

  alias Aiur.Identity
  alias Aiur.Identity.Machine

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-identity-facade-#{System.unique_integer([:positive])}")
    key = System.get_env("AIUR_INSTANCE_KEY")
    cache_keys = [{Machine, :boot_result}, {Machine, :boot_context}]
    cache = Enum.map(cache_keys, &{&1, :persistent_term.get(&1, :absent)})
    flags = [:no_dashboard, :headless, :interactive_cli, :executor_mode]
    env = Enum.map(flags, &{&1, Application.fetch_env(:aiur, &1)})

    on_exit(fn ->
      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
      for {name, value} <- cache, do: if(value == :absent, do: :persistent_term.erase(name), else: :persistent_term.put(name, value))

      for {name, value} <- env do
        case value do
          {:ok, setting} -> Application.put_env(:aiur, name, setting)
          :error -> Application.delete_env(:aiur, name)
        end
      end

      File.rm_rf!(dir)
    end)

    System.put_env("AIUR_INSTANCE_KEY", "3f9a1c0b2e")
    {:ok, machine} = Machine.ensure(dir: dir, hostname_fun: fn -> {:ok, ~c"workstation.example"} end)
    %{dir: dir, machine_id: machine.machine_id}
  end

  test "instance id joins the durable machine id and launcher key", %{machine_id: machine_id} do
    assert Identity.machine() == {:ok, %{machine_id: machine_id, label: "workstation"}}
    assert Identity.instance_key() == {:ok, "3f9a1c0b2e"}
    assert Identity.instance_id() == machine_id <> "/3f9a1c0b2e"
    assert Identity.identity_capability() == %{state: :available, reason: nil}
  end

  test "missing and empty keys give no identity and a degraded capability" do
    for key <- [nil, ""] do
      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
      assert Identity.instance_key() == {:error, :instance_key_missing}
      assert Identity.instance_id() == nil
      assert Identity.instance_section().instance_id == nil
      assert Identity.identity_capability() == %{state: :degraded, reason: :instance_key_missing}
    end
  end

  test "invalid keys are rejected rather than becoming instance ids" do
    for key <- ["has/slash", "trailing\n", " leading", "é", String.duplicate("a", 65)] do
      System.put_env("AIUR_INSTANCE_KEY", key)
      assert Identity.instance_key() == {:error, :instance_key_invalid}
      assert Identity.instance_id() == nil
      assert Identity.identity_capability() == %{state: :degraded, reason: :instance_key_invalid}
    end

    for key <- ["A", String.duplicate("a", 64), "Mixed_09-key"] do
      System.put_env("AIUR_INSTANCE_KEY", key)
      assert Identity.instance_key() == {:ok, key}
    end
  end

  test "unreadable and uncreatable machines never fabricate an identity", %{dir: dir} do
    File.write!(Path.join(dir, "identity.json"), "broken")
    assert {:degraded, :identity_unreadable, _detail} = Machine.ensure(dir: dir)
    assert_degraded_machine()
    assert {:degraded, :identity_uncreatable, _detail} = Machine.ensure(dir: Path.join(dir, "new"), random_fun: fn _ -> raise "no entropy" end)
    assert_degraded_machine()
  end

  test "run shape reflects application flags and includes the runtime version", %{machine_id: machine_id} do
    for flag <- [:no_dashboard, :headless, :interactive_cli, :executor_mode], do: Application.delete_env(:aiur, flag)

    assert Identity.instance_section() == %{
             instance_id: machine_id <> "/3f9a1c0b2e",
             aiur_version: to_string(Application.spec(:aiur, :vsn)),
             run_shape: %{http_listener: true, dashboard_pages: true, dashboard: true, headless: false, interactive_cli: false, executor_mode: false}
           }

    for flag <- [:no_dashboard, :headless, :interactive_cli, :executor_mode], do: Application.put_env(:aiur, flag, true)

    assert Identity.instance_section().run_shape == %{
             http_listener: false,
             dashboard_pages: false,
             dashboard: false,
             headless: true,
             interactive_cli: true,
             executor_mode: true
           }
  end

  test "identity before boot is unknown even with a valid key" do
    :persistent_term.erase({Machine, :boot_result})
    assert Identity.machine() == {:degraded, :not_loaded}
    assert Identity.instance_id() == nil
    assert Identity.identity_capability() == %{state: :unknown, reason: :unknown}
  end

  defp assert_degraded_machine do
    assert Identity.machine() == {:degraded, :identity_unreadable}
    assert Identity.instance_id() == nil
    assert Identity.identity_capability() == %{state: :degraded, reason: :identity_unreadable}
  end
end
