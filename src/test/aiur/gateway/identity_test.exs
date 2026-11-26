defmodule Aiur.Gateway.IdentityTest do
  use ExUnit.Case, async: false

  alias Aiur.Gateway.Identity
  alias Aiur.Identity.Machine

  @unavailable %{gateway_id: nil, gateway_label: nil, gateway_identity: "unavailable"}

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-gateway-identity-#{System.unique_integer([:positive])}")
    keys = [{Machine, :boot_result}, {Machine, :boot_context}]
    cache = Enum.map(keys, &{&1, :persistent_term.get(&1, :absent)})

    on_exit(fn ->
      for {name, value} <- cache, do: if(value == :absent, do: :persistent_term.erase(name), else: :persistent_term.put(name, value))
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    {:ok, machine} = Machine.ensure(dir: dir, hostname_fun: fn -> {:ok, ~c"workstation.example"} end)
    %{machine_id: machine.machine_id}
  end

  test "available identity carries the machine id and label", %{machine_id: id} do
    assert Identity.current() == %{gateway_id: id, gateway_label: "workstation", gateway_identity: "available"}
  end

  test "not loaded and unreadable identities are unavailable, never invented" do
    :persistent_term.erase({Machine, :boot_result})
    assert Identity.current() == @unavailable

    :persistent_term.put({Machine, :boot_result}, {:degraded, :identity_unreadable, :x})
    assert Identity.current() == @unavailable
  end
end
