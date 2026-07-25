defmodule AiurWeb.OperatorControlCenter.AgentLogModalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

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

    html =
      render_component(&AgentLogModal.agent_log_modal/1, %{
        modal: modal,
        writable: true,
        drafts: %{},
        errors: %{}
      })

    assert html =~ "not a unique writable target"
    refute html =~ ~s(phx-submit="send-operator-message")
    refute html =~ ~s(phx-click="pause-agent")
  end

  test "a unique typed running entry remains writable" do
    alpha = identity("alpha", "NODE-alpha")
    entry = %{issue_identifier: "42", tracker_identity: alpha, workspace_path: nil}
    payload = %{fleet: %{running: [entry]}}

    modal = AgentLogModal.build(entry, payload)

    assert modal.writable_target?
    assert is_binary(modal.target_key)

    html =
      render_component(&AgentLogModal.agent_log_modal/1, %{
        modal: modal,
        writable: true,
        drafts: %{modal.target_key => "typed draft"},
        errors: %{}
      })

    assert html =~ "typed draft"
    assert html =~ ~s(phx-submit="send-operator-message")
    assert html =~ ~s(phx-click="pause-agent")
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
