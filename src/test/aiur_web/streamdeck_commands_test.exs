defmodule AiurWeb.StreamdeckCommandsTest do
  # The Commands page is history-first: `history/2` pages the focused agent's
  # past Commands newest-first, `detail/2` reads one exact Command, and the
  # device answers with operator attribution so it can answer the
  # `human_required` Commands an Executor cannot. These tests run against the
  # real retained `DecisionStore` so the actor recorded in the durable record
  # is asserted exactly as it would be read back by the dashboard.
  use ExUnit.Case, async: false

  alias Aiur.{Decision, DecisionStore, DecisionValidation}
  alias AiurWeb.StreamdeckCommands

  @ticket %{identifier: "984", title: "Stream Deck Commands", url: "https://github.com/its-everdred/aiur/issues/984"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @options [
    %{"id" => "ship", "label" => "Ship it", "description" => "Merge and deploy now.", "benefits" => "Unblocks the team."},
    %{"id" => "wait", "label" => "Wait", "description" => "Hold until tomorrow.", "drawbacks" => "Slows the team.", "risk" => "Low."}
  ]

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-streamdeck-commands-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} =
      DecisionStore.start_link(
        name: nil,
        state_dir: dir,
        filesystem_sync_fun: fn -> :ok end
      )

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{store: store}
  end

  defp request!(store, source_id, authority, now) do
    payload = %{
      "source_id" => source_id,
      "question" => "Should #{source_id} ship?",
      "blocking" => true,
      "authority" => Atom.to_string(authority),
      "reversibility" => "reversible",
      "options" => @options,
      "context" => %{"short_summary" => "The checks are green for #{source_id}."}
    }

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: @ticket, source: @source, now: now], store)

    decision
  end

  test "the device answers as the operator, never the Executor" do
    assert StreamdeckCommands.actor() == %{kind: :operator, id: "streamdeck"}
  end

  test "history pages the focused agent's Commands newest-first in the allowlisted shape", %{store: store} do
    older = request!(store, "first", :human_required, ~U[2026-07-12 10:00:00Z])
    newer = request!(store, "second", :human_required, ~U[2026-07-12 11:00:00Z])

    assert {:ok, page} = StreamdeckCommands.history("984", nil, store: store)

    # Newest first, and only the focused agent's Commands.
    assert Enum.map(page["items"], & &1["decision_id"]) == [newer.decision_id, older.decision_id]
    assert Enum.all?(page["items"], &(get_in(&1, ["ticket", "identifier"]) == "984"))

    item = hd(page["items"])
    assert item["decision_id"] == newer.decision_id
    assert item["version"] == newer.version
    assert item["question"] == "Should second ship?"
    assert item["status"] == "open"
    assert item["answer"] == nil
    assert item["created_at"] == "2026-07-12T11:00:00Z"

    # The option projection is the allowlist the device renders — nothing from
    # the internal store struct leaks through.
    assert item["options"] == [
             %{"id" => "ship", "label" => "Ship it", "description" => "Merge and deploy now.", "benefits" => "Unblocks the team."},
             %{"id" => "wait", "label" => "Wait", "description" => "Hold until tomorrow.", "drawbacks" => "Slows the team.", "risk" => "Low."}
           ]

    assert item["context"] == %{"short" => "The checks are green for second."}
    assert page["has_next"] == false
    assert page["next_cursor"] == nil
    assert page["total"] == 2
    assert page["partial"] == false
  end

  test "history pages past the window with an opaque cursor", %{store: store} do
    for index <- 1..5 do
      request!(store, "q#{index}", :human_required, ~U[2026-07-12 08:00:00Z])
    end

    assert {:ok, first} = StreamdeckCommands.history("984", nil, limit: 2, store: store)
    assert length(first["items"]) == 2
    assert first["has_next"] == true
    cursor = first["next_cursor"]
    assert is_binary(cursor)

    assert {:ok, second} = StreamdeckCommands.history("984", cursor, limit: 2, store: store)
    refute Enum.any?(first["items"], &(&1["decision_id"] == hd(second["items"])["decision_id"]))
    assert second["has_next"] == true
  end

  test "detail reads one exact Command for the strip", %{store: store} do
    decision = request!(store, "exact", :human_required, ~U[2026-07-12 10:00:00Z])

    assert {:ok, item} = StreamdeckCommands.detail(decision.decision_id, store: store)
    assert item["decision_id"] == decision.decision_id
    assert item["version"] == decision.version
    assert item["status"] == "open"

    assert {:error, :not_found} = StreamdeckCommands.detail("dec_missing", store: store)
  end

  test "an answer recorded on the device carries the operator streamdeck actor", %{store: store} do
    decision = request!(store, "answer", :human_required, ~U[2026-07-12 10:00:00Z])

    payload = %{
      "idempotency_key" => "streamdeck-answer-1",
      "expected_version" => decision.version,
      "option_id" => "ship"
    }

    assert {:ok, %{status: :accepted, action: action}} =
             DecisionStore.answer(decision.decision_id, payload, [actor: StreamdeckCommands.actor()], store)

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert %Decision{answer: answer} = current
    assert answer.actor == %{kind: :operator, id: "streamdeck"}
    assert answer.selected_option_id == "ship"

    # The dashboard-facing projection records the same operator actor, with
    # the id, never an Executor answer with an operator flavour in free text.
    assert {:ok, item} = StreamdeckCommands.detail(decision.decision_id, store: store)
    assert item["answer"] == %{"selected_option_id" => "ship", "actor" => %{"kind" => "operator", "id" => "streamdeck"}}
    assert item["status"] == "decided"

    # A retry after a dropped reply is an idempotent replay, not a second
    # decision — the same key records a duplicate and the same action id.
    assert {:ok, %{status: :duplicate, action: ^action}} =
             DecisionStore.answer(decision.decision_id, payload, [actor: StreamdeckCommands.actor()], store)
  end

  test "the operator streamdeck actor can answer a human_required Command an Executor cannot", %{store: store} do
    decision = request!(store, "human", :human_required, ~U[2026-07-12 10:00:00Z])

    payload = %{
      "idempotency_key" => "streamdeck-human-1",
      "expected_version" => decision.version,
      "custom_response" => "Hold everything — verify the numbers first."
    }

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(decision.decision_id, payload, [actor: StreamdeckCommands.actor()], store)

    assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
             DecisionStore.answer(decision.decision_id, payload, [actor: %{kind: :executor, id: "executor-1"}], store)

    # The spoken custom response maps onto the CLI's `executor-answer
    # --custom-response` contract and is recorded as such.
    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.custom_response == "Hold everything — verify the numbers first."
    assert current.answer.actor == StreamdeckCommands.actor()
  end

  test "item allowlists the option and context fields the device renders", %{store: store} do
    decision = request!(store, "allowlist", :human_required, ~U[2026-07-12 10:00:00Z])
    item = StreamdeckCommands.item(decision)

    # Every value the device receives is one the client asked to render; an
    # internal field on the Decision struct is never passed through.
    assert item["options"] |> Enum.all?(&(Map.keys(&1) -- ~w(id label description benefits drawbacks risk) == []))
    assert Map.keys(item["context"]) == ["short"]
  end

  test "a store that cannot be read projects explicitly unavailable, never an empty history" do
    # `DecisionQuery.list` catches an unreadable store and returns an
    # unavailable page; the projection flags it so the device says "Commands
    # unavailable" instead of silently showing no Commands.
    assert {:ok, page} = StreamdeckCommands.history("984", nil, store: DecisionValidation)
    assert page["items"] == []
    assert page["unavailable"] == true
  end
end
