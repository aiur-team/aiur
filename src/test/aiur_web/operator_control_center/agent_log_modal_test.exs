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

  test "renders the voice choice in a writable modal composer" do
    modal = AgentLogModal.build(%{issue_identifier: 42})
    html = render_modal(modal, true)
    document = Floki.parse_document!(html)

    assert [form] = Floki.find(document, "form#agent-log-composer-42[phx-hook=VoiceInput]")
    assert Floki.attribute([form], "phx-submit") == ["send-operator-message"]
    assert [_] = Floki.find(form, "textarea[name=message][data-voice-input]")
    assert [_] = Floki.find(form, "button[type=submit][data-voice-send]")
    assert [_] = Floki.find(form, "[data-voice-chooser]")
    assert Floki.attribute(Floki.find(form, "[data-voice-mode]"), "data-voice-mode") == ["dictate", "converse"]
    assert Floki.attribute(Floki.find(form, "[data-voice-root]"), "data-voice-surface") == ["agent_composer"]
    assert [target] = Floki.attribute(Floki.find(form, "[data-voice-root]"), "data-voice-target")
    assert Jason.decode!(target) == %{"kind" => "worker", "ticket" => "42"}
    assert Floki.attribute(Floki.find(form, "[data-voice-mode=dictate]"), "aria-disabled") == ["false"]
    assert Floki.find(form, "[data-voice-conversation]") == []
  end

  # Future regression guard: also passes before voice exists; constrains where new controls render.
  test "no voice controls on a read-only, non-unique, or unavailable modal" do
    entry = %{issue_identifier: "42"}
    unique = AgentLogModal.build(entry)
    ambiguous = AgentLogModal.build(entry, %{fleet: %{running: [entry, entry]}})

    for {modal, writable} <- [{unique, false}, {ambiguous, true}, {AgentLogModal.build(nil), true}] do
      document = modal |> render_modal(writable) |> Floki.parse_document!()
      assert Floki.find(document, "[data-voice-root], [phx-hook=VoiceInput], [data-voice-mode]") == []
      assert Floki.find(document, "form") == []
    end
  end

  defp render_modal(modal, writable) do
    render_component(&AgentLogModal.agent_log_modal/1, %{
      modal: modal,
      writable: writable,
      drafts: %{},
      errors: %{},
      voice_capabilities: %{"voice.stt" => %{state: :available}}
    })
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
