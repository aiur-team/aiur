defmodule Aiur.Orchestrator.OwnershipLeaseOptionalTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.Orchestrator.{Dispatcher, State}

  @self %{gateway_id: "pc", gateway_label: "pc", daemon_key: "k1"}

  defp owned_issue(number) do
    %Aiur.Issue{
      id: number,
      identifier: number,
      tracker_identity: %Aiur.TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "Acme",
        repository: "Widgets",
        provider_id: "issue-node-#{number}",
        identifier: number,
        reason: nil
      },
      title: "t",
      state: "todo",
      selected_backend: "codex",
      labels: ["gateway:pc"]
    }
  end

  defp dispatch(issue, extra) do
    parent = self()
    record = Map.put(@self, :state, "owned")

    opts =
      [
        ownership_enabled: true,
        ownership_self: @self,
        ownership_read_fun: fn _, _, _ -> {:ok, %{record: record}} end,
        lease_claim_fun: fn _ -> :acquired end,
        runner: fn _, _, _ ->
          send(parent, :runner_started)
          :ok
        end
      ]
      |> Keyword.merge(extra)

    Dispatcher.do_dispatch_issue(%State{max_concurrent_agents: 1, effective_concurrent_agents: 1}, issue, nil, nil, opts)
  end

  # `owns` must be configured or the store-unset branch is never reached.
  defp configure_owns! do
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file!(path)
    write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  owns:\n    - label: gateway:pc\n")
    :ok = Aiur.WorkflowStore.force_reload()
    assert Aiur.Instance.ownership_configured?()
  end

  test "owned by self with no lease store and an owns rule: dispatch proceeds" do
    configure_owns!()
    state = dispatch(owned_issue("own-1"), ownership_live_instances_fun: fn -> {:error, :store_not_configured} end)

    assert MapSet.member?(state.claimed, "own-1")
  end

  test "store up, a peer's owns-rule matches, this gateway owns the ref: dispatch proceeds" do
    peer = %{instance_id: "peer", metadata: %{"version" => 1, "data" => %{"owns" => [%{"label" => "gateway:pc"}], "pool" => false, "dispatching" => true}}}
    me = %{instance_id: "me", metadata: %{"version" => 1, "data" => %{"owns" => [], "pool" => false, "dispatching" => true}}}

    state =
      dispatch(owned_issue("own-6"),
        ownership_instance_id: "me",
        ownership_live_instances_fun: fn -> {:ok, [peer, me]} end
      )

    assert MapSet.member?(state.claimed, "own-6")
  end

  test "store down: the GitHub claim decides, no roster hold" do
    state = dispatch(owned_issue("own-2"), ownership_live_instances_fun: fn -> {:error, :econnrefused} end)

    assert MapSet.member?(state.claimed, "own-2")
  end

  test "store down mid-claim: dispatch degrades instead of holding" do
    state =
      dispatch(owned_issue("own-3"),
        ownership_live_instances_fun: fn -> {:error, :store_not_configured} end,
        lease_claim_fun: fn _ -> {:error, :econnrefused} end
      )

    assert MapSet.member?(state.claimed, "own-3")
  end

  test "store up: a second run while the first renews its lease is refused" do
    state =
      dispatch(owned_issue("own-4"),
        ownership_live_instances_fun: fn -> {:error, :store_not_configured} end,
        lease_claim_fun: fn _ -> :held end
      )

    refute MapSet.member?(state.claimed, "own-4")
    refute_receive :runner_started, 0
  end

  test "ownership off keeps the roster hold when the store is down" do
    state =
      dispatch(owned_issue("own-5"),
        ownership_enabled: false,
        ownership_live_instances_fun: fn -> {:error, :econnrefused} end
      )

    assert state.dispatch_declines["own-5"] == :instance_ownership_unavailable
  end
end
