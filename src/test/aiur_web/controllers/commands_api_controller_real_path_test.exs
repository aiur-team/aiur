defmodule AiurWeb.CommandsApiControllerRealPathTest do
  # Drives the controller through the real HostApi and a real DecisionStore, so the
  # 422 comes from the code path production takes, not from a stubbed error shape.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.Commands.Scope
  alias Aiur.DecisionStore
  alias AiurWeb.CommandsApiController

  @secret String.duplicate("s", 64)
  @now ~U[2026-11-05 12:00:00Z]

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    original = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-commands-controller")
    Application.put_env(:aiur, :decision_state_dir, dir)
    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "feedback the store refuses is a real HTTP 422 and leaves the decision unanswered", %{store: store} do
    decision = request!(store)

    params = %{
      "decision_id" => decision.decision_id,
      "idempotency_key" => "submit-1",
      "expected_version" => decision.version,
      "option_id" => "approve",
      "feedback" => [%{"option_id" => "nope", "verdict" => "like"}]
    }

    conn = conn_for(store) |> CommandsApiController.answer(params)

    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "invalid_request"
    assert body["command"]["state"] == "error"
    assert body["command"]["reason"] == "validation_failed"

    assert {:ok, %{decision: unchanged}} = Aiur.DecisionQuery.get(decision.decision_id, store: store)
    assert unchanged.answer == nil
  end

  defp conn_for(store) do
    {:ok, %{scope: scope}} = Scope.mint("player-7", ["42"], secret: @secret, now: @now)

    :post
    |> conn("/api/v1/commands")
    |> assign(:command_scope, scope)
    |> Map.put(:private, %{command_store: store})
  end

  defp request!(store) do
    payload = %{
      "source_id" => "real-path",
      "question" => "What now?",
      "blocking" => true,
      "kind" => "architecture",
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible",
      "options" => [%{"id" => "approve", "label" => "Approve"}, %{"id" => "hold", "label" => "Hold"}],
      "recommendation" => %{"option_id" => "approve"},
      "artifacts" => ["https://github.com/aiur-team/aiur/issues/42"]
    }

    ticket = %{identifier: "42", title: "Ticket 42", url: "https://example.test/issues/42"}
    source = %{agent_id: "agent-1", session_id: "session-1", event_id: nil}

    assert {:ok, %{decision: decision}} = DecisionStore.request(payload, [ticket: ticket, source: source, now: @now], store)
    decision
  end
end
