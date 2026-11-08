Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Gateway.CliTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Gateway.{Cli, Registry}
  alias Aiur.Identity.Machine

  @peer "aaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup %{dir: dir} do
    keys = [{Machine, :boot_result}, {Machine, :boot_context}]
    previous = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})
    env = [:gateway_registry_path, :control_audit_file, :client_tokens_path]
    previous_env = Map.new(env, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :gateway_registry_path, Path.join(dir, "remote-instances.yaml"))
    Application.put_env(:aiur, :control_audit_file, Path.join(dir, "control-audit.ndjson"))
    Application.put_env(:aiur, :client_tokens_path, Path.join(dir, "tokens.json"))
    {:ok, _} = Machine.ensure(dir: Path.join(dir, "machine"))
    File.write!(Path.join(dir, "remote-instances.yaml"), "version: 1\ninstances:\n  nook:\n    label: Nook\n    gateway_id: \"#{@peer}\"\n  pc:\n    gateway_id: \"bbbbbbbbbbbbbbbbbbbbbbbbbb\"\n")

    on_exit(fn ->
      for {k, v} <- previous, do: if(v == :absent, do: :persistent_term.erase(k), else: :persistent_term.put(k, v))
      for {k, v} <- previous_env, do: if(is_nil(v), do: Application.delete_env(:aiur, k), else: Application.put_env(:aiur, k, v))
    end)

    %{store: start_supervised_store!(dir)}
  end

  defp run(fun, opts), do: ExUnit.CaptureIO.capture_io(fn -> ExUnit.CaptureIO.capture_io(:stderr, fn -> apply(Cli, fun, [opts]) end) |> IO.write() end)
  defp categories(name \\ "nook"), do: elem(Registry.get(), 1).peers[name].categories
  defp exit_code(out), do: out |> then(&Regex.run(~r/__AIUR_CONTROL_EXIT__:(\d+)/, &1)) |> List.last() |> String.to_integer()

  test "granting read writes at once and raises no Decision", %{store: store} do
    out = run(:grant, peer: "nook", categories: ["read"], store: store)
    assert exit_code(out) == 0
    assert categories() == ["read"]
    assert DecisionStore.list(store) == []
  end

  test "granting a write category leaves the file alone and raises one open Decision", %{store: store} do
    out = run(:grant, peer: "Nook", categories: ["agents"], store: store)
    assert exit_code(out) == 0
    assert out =~ "Decision"
    assert categories() == ["read"]
    assert [%{kind: "gateway_grant", decision_status: :open}] = DecisionStore.list(store)

    run(:grant, peer: "nook", categories: ["agents"], store: store)
    assert length(DecisionStore.list(store)) == 1
  end

  test "trust without --full and trust as a category are refused", %{store: store} do
    assert exit_code(run(:trust, peer: "nook", store: store)) == 64
    assert exit_code(run(:grant, peer: "nook", categories: ["trust"], store: store)) == 64
    assert DecisionStore.list(store) == []
  end

  test "trust --full requests exactly the six grantable categories and never trust", %{store: store} do
    out = run(:trust, peer: "nook", full: true, store: store)
    assert exit_code(out) == 0
    assert categories() == ["read"]
    [decision] = DecisionStore.list(store)
    assert {:ok, _peer, pending, _digest} = Aiur.Gateway.GrantRequest.parse(decision.source_id)
    assert Enum.sort(pending ++ ["read"]) == Enum.sort(Registry.categories())
    refute "trust" in pending
  end

  test "revoke with categories removes just those and leaves tokens", %{store: store} do
    File.write!(Registry.path(), "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n    allows:\n      categories: [read, agents, message]\n")
    {:ok, _token} = Aiur.ClientTokens.create("nook-token", "write", peer: @peer, categories: ["read", "agents"])

    assert exit_code(run(:revoke, peer: "nook", categories: ["agents"], store: store)) == 0
    assert categories() == ["read", "message"]
    assert {:ok, ["nook-token"]} = Aiur.ClientTokens.list_for_peer(@peer)
  end

  test "revoke without categories empties the grants and deletes the peer's tokens and credentials", %{store: store} do
    File.write!(Registry.path(), "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n    allows:\n      categories: [read, agents]\n      credentials: [named-token]\n")
    {:ok, _} = Aiur.ClientTokens.create("bound-token", "write", peer: @peer, categories: ["read"])
    {:ok, _} = Aiur.ClientTokens.create("named-token", "read")
    {:ok, _} = Aiur.ClientTokens.create("bystander", "read")

    assert exit_code(run(:revoke, peer: "nook", store: store)) == 0
    assert categories() == []
    {:ok, remaining} = Aiur.ClientTokens.list()
    assert Enum.map(remaining, & &1["name"]) == ["bystander"]
    assert elem(Registry.get(), 1).peers["nook"].credentials == []
  end

  test "revoke of an unknown peer exits 66 and writes nothing", %{store: store} do
    before = File.read!(Registry.path())
    assert exit_code(run(:revoke, peer: "ghost", store: store)) == 66
    assert File.read!(Registry.path()) == before
  end

  test "permissions lists the peers and reports a rejected file", %{store: store} do
    out = run(:permissions, store: store)
    assert out =~ "nook\tNook\taaaaaaaa\tread"
    assert exit_code(out) == 0

    json = run(:permissions, json: true, store: store) |> String.split("\n") |> hd() |> Jason.decode!()
    assert json["freshness"] == "current"
    assert is_integer(json["age_ms"])
    assert Enum.map(json["peers"], & &1["name"]) == ["nook", "pc"]

    assert exit_code(run(:permissions, peer: "ghost", store: store)) == 66
  end
end
