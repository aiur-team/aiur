defmodule AiurWeb.OperatorControlCenter.ConversationDrawer.PresenterTest do
  use Aiur.TestSupport

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter

  @observed_at ~U[2026-07-17 12:00:00Z]

  defp identity do
    struct!(TrackerIdentity,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "NODE-1110",
      database_id: 1110,
      identifier: "1110"
    )
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Responsive Units interface",
        identity: identity(),
        agent_family: :codex,
        backend: :codex,
        requested_model: "gpt-5.6-terra",
        resolved_model: "gpt-5.6-terra-2026",
        live_conversation: %{generation_handle: "conversation:" <> String.duplicate("a", 43)}
      },
      overrides
    )
  end

  defp message(overrides \\ %{}) do
    Map.merge(
      %{
        id: "m1",
        role: "agent",
        title: "Assistant",
        body: "Working on the drawer.",
        occurred_at: @observed_at,
        observed_at: @observed_at
      },
      overrides
    )
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        state: :live,
        health: :healthy,
        freshness: :current,
        messages: [message()],
        observed_at: @observed_at,
        truncated?: false,
        evicted_count: 0,
        source: %{worker_generation: 4, session_id: "opaque-session"}
      },
      overrides
    )
  end

  test "presents typed identity, normalized metadata, and the read-only notice" do
    view = Presenter.present(row(), snapshot())

    assert view.heading.title == "Responsive Units interface"
    assert view.heading.identity_label == "its-everdred/aiur #1110"
    assert view.participation_notice =~ "not participating"

    metadata = Map.new(view.metadata, &{&1.key, &1.value})
    assert metadata.agent == "Codex"
    assert metadata.requested_model == "gpt-5.6-terra"
    assert metadata.resolved_model == "gpt-5.6-terra-2026"
    refute Map.has_key?(metadata, :generation)
    refute Map.has_key?(metadata, :session)
  end

  test "labels unknown optional facts as unknown rather than fabricating them" do
    view =
      Presenter.present(
        row(%{requested_model: nil, resolved_model: nil, agent_family: nil}),
        snapshot(%{source: %{worker_generation: nil, session_id: nil}})
      )

    metadata = Map.new(view.metadata, &{&1.key, &1.value})
    assert metadata.requested_model == "Unknown"
    assert metadata.resolved_model == "Unknown"
    assert metadata.agent == "Unknown"
    refute Map.has_key?(metadata, :generation)
    refute Map.has_key?(metadata, :session)
  end

  test "orders messages deterministically by occurrence then id and labels roles" do
    later = DateTime.add(@observed_at, 60, :second)

    messages = [
      message(%{id: "b", role: "operator", occurred_at: later, body: "second"}),
      message(%{id: "a", role: "tool", occurred_at: @observed_at, title: "grep", body: "first"})
    ]

    view = Presenter.present(row(), snapshot(%{messages: messages}))

    assert Enum.map(view.messages, & &1.id) == ["a", "b"]
    assert Enum.map(view.messages, & &1.role_label) == ["Tool summary", "Operator"]
    assert view.message_count == 2
    refute view.empty?
  end

  test "drops malformed messages that are not fully sanitized maps" do
    messages = [message(), %{id: "bad"}, "raw", message(%{id: "m2", body: "ok"})]

    view = Presenter.present(row(), snapshot(%{messages: messages}))

    assert Enum.map(view.messages, & &1.id) == ["m1", "m2"]
  end

  for state <- [:live, :ended, :known_empty, :stale, :unavailable, :restart_unknown] do
    test "carries the #{state} snapshot state with a truthful label and detail" do
      view = Presenter.present(row(), snapshot(%{state: unquote(state), messages: []}))

      assert view.state == unquote(state)
      assert is_binary(view.state_label)
      assert is_binary(view.state_detail)
    end
  end

  test "live? is only true for an active live snapshot" do
    assert Presenter.present(row(), snapshot(%{state: :live})).live?
    refute Presenter.present(row(), snapshot(%{state: :ended})).live?
    refute Presenter.present(row(), snapshot(%{state: :live}), :superseded).live?
  end

  test "a superseded drawer freezes to an ended-generation state, never the live snapshot" do
    view = Presenter.present(row(), snapshot(%{state: :live}), :superseded)

    assert view.state == :superseded
    assert view.state_label == "Superseded"
    assert view.state_detail =~ "newer worker generation"
    refute view.live?
  end

  test "an out-of-scope drawer freezes rather than adopting the live snapshot" do
    view = Presenter.present(row(), snapshot(%{state: :live}), :out_of_scope)

    assert view.state == :out_of_scope
    assert view.state_detail =~ "no longer in the current run"
    refute view.live?
  end

  test "reports truncation and eviction counts without dropping the bound" do
    view = Presenter.present(row(), snapshot(%{truncated?: true, evicted_count: 3}))

    assert view.truncated?
    assert view.evicted_count == 3
    assert view.truncation_note =~ "3 earlier"
  end

  test "a nil snapshot degrades to an unavailable, empty projection" do
    view = Presenter.present(row(), nil)

    assert view.state == :unavailable
    assert view.empty?
    assert view.messages == []
    assert view.health_label == "Unavailable"
  end

  test "missing typed identity is labelled unavailable, not blank" do
    view = Presenter.present(row(%{identity: nil}), snapshot())
    assert view.heading.identity_label == "Unknown ticket"
  end
end
