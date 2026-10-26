defmodule Aiur.Commands.ActorSourceTest do
  use ExUnit.Case, async: true
  alias Aiur.Commands.ActorSource
  alias Aiur.DecisionAnswer

  test "entry-point options accept only closed atoms" do
    for source <- [:rpc, :dashboard_session, :basic_auth, :device, :cli, :relay_cli, :executor_cli, :supervisor_api] do
      assert ActorSource.from_opts(actor_source: source) == source
    end

    assert ActorSource.from_opts(actor_source: "device") == :rpc
    assert ActorSource.from_opts(actor_source: :unknown) == :rpc
    assert ActorSource.from_opts([]) == :rpc
  end

  test "actor provenance round trips while older answers keep their hash and retry identity" do
    payload = %{expected_version: 1, custom_response: "Proceed", idempotency_key: "legacy"}
    opts = [decision_id: "decision", decision_version: 1, actor: %{kind: :operator, id: "human"}]
    assert {:ok, legacy} = DecisionAnswer.normalize(payload, opts)
    assert {:ok, current} = DecisionAnswer.normalize(payload, Keyword.put(opts, :actor, %{kind: :operator, id: "human", source: :device}))
    assert current.actor.source == :device
    assert legacy.content_hash == current.content_hash
    assert {:ok, decoded} = current |> DecisionAnswer.to_event_json_safe() |> DecisionAnswer.from_json_safe()
    assert decoded.actor.source == :device
    assert {:ok, old} = legacy |> DecisionAnswer.to_event_json_safe() |> DecisionAnswer.from_json_safe()
    refute Map.has_key?(old.actor, :source)
  end

  test "event actor codec retains recognized source without inventing one for old records" do
    actor = %{kind: :operator, id: "human", source: :dashboard_session}
    assert {:ok, event} = Aiur.DecisionEvent.Codec.normalize_data(:decision_deferred, %{actor: actor}, "decision", 1, nil)
    assert event.actor.source == :dashboard_session
    assert Aiur.DecisionEvent.Codec.data_to_json_safe(:decision_deferred, event)["actor"]["source"] == "dashboard_session"
    assert {:ok, legacy} = Aiur.DecisionEvent.Codec.normalize_data(:decision_deferred, %{actor: %{kind: :operator, id: "human"}}, "decision", 1, nil)
    refute Map.has_key?(legacy.actor, :source)
  end
end
