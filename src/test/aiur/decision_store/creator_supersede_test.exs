Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.CreatorSupersedeTest do
  # Workers re-ask the creator within one review round (open-games #548 raised
  # two questions ten minutes apart; #366 asked six in ninety minutes). The
  # creator should only ever face the question the ticket is asking now.
  use Aiur.DecisionStoreCase, async: false

  defp ask(pid, question, extra \\ %{}, ticket \\ "979") do
    payload = Map.merge(%{"question" => question, "blocking" => false, "audience" => "creator", "options" => [%{"id" => "yes", "label" => "Yes"}]}, extra)
    assert {:ok, %{status: :accepted, decision: decision}} = request(pid, payload, ticket: %{@ticket | identifier: ticket})
    decision
  end

  defp status(pid, decision), do: elem(DecisionStore.get(decision.decision_id, pid), 1).decision_status

  test "a new creator Command moots the ticket's older open creator Commands and names its replacement", %{dir: dir} do
    pid = start_store!(dir)
    thumbnail = ask(pid, "Which thumbnail revision should ship?")
    human = ask(pid, "Approve the new pricing copy?", %{"audience" => nil, "authority" => "human_required"})
    card = ask(pid, "Use the card with the logo?")

    for {older, newer} <- [{thumbnail, human}, {human, card}] do
      assert status(pid, older) == :moot
      {:ok, events} = DecisionStore.audit_history(older.decision_id, pid)
      moot = Enum.find(events, &match?(%DecisionEvent{type: :decision_mooted}, &1))
      assert moot.data.reason_class == "superseded"
      assert moot.data.detail == "Replaced by #{newer.decision_id}."
    end

    assert status(pid, card) == :open
    GenServer.stop(pid)
  end

  test "answered, Executor-bound, grouped and other-ticket Commands are left alone", %{dir: dir} do
    pid = start_store!(dir)
    answered = ask(pid, "Keep the old banner?")
    assert {:ok, _} = answer(pid, answered.decision_id, %{expected_version: 1, option_id: "yes", idempotency_key: "keep-banner"})
    executor = ask(pid, "Retry the flaky job?", %{"audience" => "executor"})
    grouped = ask(pid, "Adopt proposal A?", %{"tags" => ["group:a"]})
    elsewhere = ask(pid, "Ship the other ticket?", %{}, "980")
    newest = ask(pid, "Which color for proposal A?", %{"tags" => ["group:a"]})

    assert status(pid, answered) == :decided
    assert status(pid, executor) == :open
    assert status(pid, grouped) == :open
    assert status(pid, elsewhere) == :open
    assert status(pid, newest) == :open

    # Outside the group, the next creator question still replaces the grouped ones.
    latest = ask(pid, "Publish now?")
    assert status(pid, grouped) == :moot
    assert status(pid, newest) == :moot
    assert status(pid, latest) == :open
    GenServer.stop(pid)
  end

  test "a duplicate re-ask keeps the open Command instead of replacing it", %{dir: dir} do
    pid = start_store!(dir)
    first = ask(pid, "Which thumbnail revision should ship?")
    payload = %{"question" => "Which thumbnail revision should ship?", "blocking" => false, "audience" => "creator", "source_id" => "again"}
    assert {:ok, %{status: :duplicate}} = request(pid, payload)
    assert status(pid, first) == :open
    GenServer.stop(pid)
  end
end
