Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Gateway.GrantConfirmationTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Commands.Answering
  alias Aiur.Gateway.{GrantConfirmation, GrantRequest, Registry}
  alias Aiur.Identity.Machine

  @peer "aaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup %{dir: dir} do
    keys = [{Machine, :boot_result}, {Machine, :boot_context}]
    previous = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})
    env = [:gateway_registry_path, :control_audit_file]
    previous_env = Map.new(env, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :gateway_registry_path, Path.join(dir, "remote-instances.yaml"))
    Application.put_env(:aiur, :control_audit_file, Path.join(dir, "control-audit.ndjson"))
    {:ok, %{machine_id: gateway_id}} = Machine.ensure(dir: Path.join(dir, "machine"))
    File.write!(Path.join(dir, "remote-instances.yaml"), "version: 1\ninstances:\n  nook:\n    label: Nook\n    gateway_id: \"#{@peer}\"\n")

    on_exit(fn ->
      for {k, v} <- previous, do: if(v == :absent, do: :persistent_term.erase(k), else: :persistent_term.put(k, v))
      for {k, v} <- previous_env, do: if(is_nil(v), do: Application.delete_env(:aiur, k), else: Application.put_env(:aiur, k, v))
    end)

    store = start_supervised_store!(dir)
    {:ok, %{peers: %{"nook" => peer}}} = Registry.get()
    %{store: store, peer: peer, gateway_id: gateway_id, audit: Path.join(dir, "control-audit.ndjson")}
  end

  defp proof(method, age \\ 60), do: %{method: method, subject: "kevin@example.test", authenticated_at: System.system_time(:second) - age}
  defp categories, do: elem(Registry.get(), 1).peers["nook"].categories

  defp audit_events(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "a grant request raises one human-required Decision per peer and category set", %{store: store, peer: peer} do
    assert {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)
    assert decision.kind == "gateway_grant"
    assert decision.authority == :human_required
    assert {:ok, same} = GrantRequest.request(peer, ["agents"], store: store)
    assert same.decision_id == decision.decision_id
    assert length(DecisionStore.list(store)) == 1
    assert categories() == ["read"]
  end

  test "a fresh Google session approves the grant and the registry gains the categories", %{store: store, peer: peer, audit: audit} do
    {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)

    assert {:ok, :approved} = GrantConfirmation.confirm(decision.decision_id, "approve", proof(:google), store: store)

    assert categories() == ["read", "agents"]
    assert {:ok, %{decision_status: status}} = DecisionStore.get(decision.decision_id, store)
    assert status != :open
    events = audit_events(audit)
    assert %{"actor" => "dashboard_google", "method" => "google", "subject" => "kevin@example.test"} = Enum.find(events, &(&1["event"] == "grant_confirmed"))
    assert %{"actor" => "dashboard_google"} = Enum.find(events, &(&1["event"] == "grant_written"))
  end

  test "a passkey session approves with method passkey", %{store: store, peer: peer, audit: audit} do
    {:ok, decision} = GrantRequest.request(peer, ["message"], store: store)
    assert {:ok, :approved} = GrantConfirmation.confirm(decision.decision_id, "approve", proof(:passkey), store: store)
    assert %{"method" => "passkey", "actor" => "dashboard_passkey"} = Enum.find(audit_events(audit), &(&1["event"] == "grant_confirmed"))
  end

  test "a sign-in older than the freshness window changes nothing", %{store: store, peer: peer} do
    {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)
    stale = proof(:google, GrantConfirmation.fresh_seconds() + 1)

    assert {:error, :session_not_fresh} = GrantConfirmation.confirm(decision.decision_id, "approve", stale, store: store)
    assert categories() == ["read"]
    assert {:ok, %{decision_status: :open}} = DecisionStore.get(decision.decision_id, store)
  end

  test "a session with no Google or passkey sign-in cannot confirm", %{store: store, peer: peer} do
    {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)

    for bad <- [%{}, nil, Map.put(proof(:google), :method, :basic)] do
      assert {:error, :human_session_required} = GrantConfirmation.confirm(decision.decision_id, "approve", bad, store: store)
    end

    assert categories() == ["read"]
  end

  test "every generic answer path refuses a grant Decision, including as an operator", %{store: store, peer: peer} do
    {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)
    payload = %{"option_id" => "approve", "expected_version" => decision.version}
    operator = %{kind: :operator, id: "dashboard"}
    opts = [actor: operator, actor_source: :dashboard_session, client: %{surface: :dashboard}, store: store]

    assert %{status: :error, reason: :grant_requires_session_confirmation} = Answering.answer(decision.decision_id, Map.put(payload, "idempotency_key", "a"), opts)
    assert %{status: :error, reason: :grant_requires_session_confirmation} = Answering.override(decision.decision_id, Map.put(payload, "idempotency_key", "b"), opts)
    assert %{status: :error, reason: :grant_requires_session_confirmation} = Answering.supersede(decision.decision_id, Map.put(payload, "idempotency_key", "c"), opts)
    assert {:error, :grant_requires_session_confirmation} = DecisionStore.answer(decision.decision_id, Map.put(payload, "idempotency_key", "d"), [actor: operator], store)

    executor = [actor: %{kind: :executor, id: "executor"}, actor_source: :cli, client: %{surface: :cli}, store: store]
    assert %{status: :error, reason: :grant_requires_session_confirmation} = Answering.answer(decision.decision_id, Map.put(payload, "idempotency_key", "e"), executor)

    assert categories() == ["read"]
  end

  test "a forged proof struct field is not enough: the store wants the struct confirm builds", %{store: store, peer: peer} do
    {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)
    payload = %{"option_id" => "approve", "expected_version" => decision.version, "idempotency_key" => "f"}
    forged = [actor: %{kind: :operator, id: "dashboard"}, grant_confirmation: %{method: :google}]

    assert {:error, :grant_requires_session_confirmation} = DecisionStore.answer(decision.decision_id, payload, forged, store)
  end

  test "deny writes nothing and is audited", %{store: store, peer: peer, audit: audit} do
    {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)
    assert {:ok, :denied} = GrantConfirmation.confirm(decision.decision_id, "deny", proof(:google), store: store)
    assert categories() == ["read"]
    assert Enum.any?(audit_events(audit), &(&1["event"] == "grant_denied"))
  end

  test "a Decision raised for another gateway id never confirms here", %{store: store, peer: peer, dir: dir} do
    {:ok, decision} = GrantRequest.request(peer, ["agents"], store: store)
    {:ok, _other} = Machine.ensure(dir: Path.join(dir, "other-machine"))

    assert {:error, :stale_grant} = GrantConfirmation.confirm(decision.decision_id, "approve", proof(:google), store: store)
    assert categories() == ["read"]
  end

  test "a non-grant Decision cannot be confirmed through this path", %{store: store} do
    {:ok, %{decision: other}} = Aiur.Commands.request(%{question: "Pick one?", blocking: false}, [ticket: %{identifier: "979", title: "t", url: "https://example.test/979"}], store)
    assert {:error, :not_a_grant} = GrantConfirmation.confirm(other.decision_id, "approve", proof(:google), store: store)
  end
end
