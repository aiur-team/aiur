defmodule VoiceConverse.DraftsTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Drafts

  @draft_id "vd_" <> String.duplicate("a", 22)
  @at "2026-10-26T12:00:00Z"

  test "propose_instruction creates a redacted proposed draft record" do
    assert {:ok, draft, projection} =
             Drafts.propose_instruction(Drafts.new(), "Bearer secret",
               target: %{id: "target"},
               at: @at,
               redactor: fn _ -> "[redacted]" end,
               id_generator: fn -> @draft_id end
             )

    assert draft.draft_id == @draft_id
    assert draft.kind == :instruction
    assert draft.status == :proposed
    assert draft.text == "[redacted]"
    assert draft.target == %{id: "target"}
    assert Drafts.fetch(projection, @draft_id) == {:ok, draft}

    assert Drafts.record(draft) == %{
             type: "draft",
             draft_id: @draft_id,
             kind: "instruction",
             status: "proposed",
             text: "[redacted]",
             target: %{id: "target"},
             at: @at
           }
  end

  test "only listed transitions are allowed" do
    {:ok, draft, projection} = propose(Drafts.new())

    for {from, to, allowed?} <- transition_cases() do
      projection = put_status(projection, draft, from)

      if allowed? do
        assert {:ok, %{status: ^to}, _projection} = Drafts.transition(projection, draft.draft_id, to, at: @at)
      else
        assert {:error, :invalid_transition} = Drafts.transition(projection, draft.draft_id, to, at: @at)
        assert {:ok, %{status: ^from}} = Drafts.fetch(projection, draft.draft_id)
      end
    end
  end

  test "projection replay yields the live state" do
    {:ok, proposed, projection} = propose(Drafts.new())

    {:ok, confirmed, projection} =
      Drafts.confirm(projection, proposed.draft_id, %{source: :client_socket, principal: %{id: "operator"}}, at: @at)

    {:ok, sent, _projection} = Drafts.transition(projection, proposed.draft_id, :sent, at: @at)

    assert {:ok, replayed} = Drafts.replay([Drafts.record(proposed), Drafts.record(confirmed), Drafts.record(sent)])
    assert Drafts.fetch(replayed, proposed.draft_id) == {:ok, sent}
  end

  test "the sixth open draft is refused" do
    projection =
      Enum.reduce(1..5, Drafts.new(), fn index, projection ->
        {:ok, _draft, projection} = propose(projection, id: draft_id(index))
        projection
      end)

    assert {:error, :too_many_open_drafts} =
             Drafts.propose_instruction(projection, "sixth",
               target: %{id: "target"},
               at: @at,
               id_generator: fn -> draft_id(6) end
             )
  end

  test "confirmation requires a client socket source" do
    {:ok, draft, projection} = propose(Drafts.new())

    for source <- [:provider_tool, :provider_transcript, :host_callback, :client] do
      assert {:error, :not_client} = Drafts.confirm(projection, draft.draft_id, %{source: source}, at: @at)
      assert {:ok, %{status: :proposed}} = Drafts.fetch(projection, draft.draft_id)
    end
  end

  test "invalid text is refused without creating a draft" do
    projection = Drafts.new()

    assert {:error, :invalid_text} = Drafts.propose_instruction(projection, "", target: %{id: "target"}, at: @at)

    assert {:error, :text_too_long} =
             Drafts.propose_instruction(projection, String.duplicate("a", 4_001), target: %{id: "target"}, at: @at)

    assert Drafts.open(projection) == []
  end

  defp propose(projection, opts \\ []) do
    id = Keyword.get(opts, :id, @draft_id)

    Drafts.propose_instruction(projection, "ship it", target: %{id: "target"}, at: @at, id_generator: fn -> id end)
  end

  defp put_status(_projection, draft, status) do
    draft = %{draft | status: status}
    {:ok, projection} = Drafts.replay([Drafts.record(draft)])
    projection
  end

  defp draft_id(index), do: "vd_" <> String.pad_leading(Integer.to_string(index), 22, "a")

  defp transition_cases do
    statuses = [:proposed, :confirmed, :sent, :delivered, :failed, :discarded, :stale]

    allowed =
      MapSet.new([
        {:proposed, :confirmed},
        {:proposed, :discarded},
        {:proposed, :stale},
        {:confirmed, :sent},
        {:sent, :delivered},
        {:sent, :failed},
        {:failed, :confirmed}
      ])

    for from <- statuses, to <- statuses, from != to, do: {from, to, MapSet.member?(allowed, {from, to})}
  end
end
