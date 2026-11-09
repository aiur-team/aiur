defmodule AiurWeb.OperatorControlCenter.AgentLogModalTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.AgentLogModal

  test "finds the exact repository-qualified running entry when identifiers collide" do
    alpha = identity("alpha", "NODE-alpha")
    beta = identity("beta", "NODE-beta")

    payload = %{
      fleet: %{
        running: [
          %{issue_identifier: "42", tracker_identity: alpha, workspace_path: nil},
          %{issue_identifier: "42", tracker_identity: beta, workspace_path: nil}
        ]
      }
    }

    assert %{tracker_identity: ^alpha} = AgentLogModal.find_running_entry(payload, alpha)
    assert %{tracker_identity: ^beta} = AgentLogModal.find_running_entry(payload, beta)

    modal = payload |> AgentLogModal.find_running_entry(beta) |> AgentLogModal.build(payload)

    assert modal.tracker_identity == beta
    refute modal.writable_target?
  end

  test "a unique typed running entry remains writable" do
    alpha = identity("alpha", "NODE-alpha")
    entry = %{issue_identifier: "42", tracker_identity: alpha, workspace_path: nil}
    payload = %{fleet: %{running: [entry]}}

    modal = AgentLogModal.build(entry, payload)

    assert modal.writable_target?
    assert is_binary(modal.target_key)
  end

  defp identity(repository, provider_id) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "acme",
      repository: repository,
      provider_id: provider_id,
      identifier: "42",
      reason: nil
    }
  end
end
