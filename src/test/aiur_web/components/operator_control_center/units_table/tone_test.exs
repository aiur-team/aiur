defmodule AiurWeb.OperatorControlCenter.UnitsTableToneTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsTable}

  import AiurWeb.OperatorControlCenter.UnitsTableFixtures

  test "reserves the red alert treatment for rows blocked awaiting a command/decision" do
    html = render(view([row_with_tone(:blocked)]))

    assert html =~ ~s(class="units-row is-blocked")
    refute html =~ ~s(class="ut-alert")
  end

  test "paused and queued rows never render red even with blocking/alert reasons" do
    paused = render(view([row_with_tone(:paused_with_attention)]))
    queued = render(view([row_with_tone(:queued_with_attention)]))

    assert paused =~ ~s(class="units-row is-paused")
    refute paused =~ ~s(class="units-row is-blocked")
    refute paused =~ ~s(class="units-row has-alert")

    assert queued =~ ~s(class="units-row is-queued")
    refute queued =~ ~s(class="units-row is-blocked")
    refute queued =~ ~s(class="units-row has-alert")
  end

  test "renders active, queued, and paused rows with distinct non-red tones" do
    active = render(view([row_with_tone(:active)]))
    queued = render(view([row_with_tone(:queued)]))
    paused = render(view([row_with_tone(:paused)]))

    # Active is neutral: no tone class and no warning glyph.
    refute active =~ ~s(is-blocked)
    refute active =~ ~s(is-paused)
    refute active =~ ~s(is-queued)
    refute active =~ ~s(has-alert)
    refute active =~ ~s(class="ut-alert")

    # Queued is muted and never carries the red-blocking or warning treatment.
    assert queued =~ ~s(class="units-row is-queued")
    refute queued =~ ~s(is-blocked)
    refute queued =~ ~s(class="ut-alert")

    # Paused is a subtle amber/gray tone, distinct from blocked red.
    assert paused =~ ~s(class="units-row is-paused")
    refute paused =~ ~s(is-blocked)
    refute paused =~ ~s(class="ut-alert")
  end

  test "offers the explicit Read conversation action only when a valid handle is present" do
    handle = "conversation:" <> String.duplicate("a", 43)
    row = Map.put(row(), :live_conversation, %{generation_handle: handle})
    token = UnitsPresenter.row_token(row)

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(id="units-conversation-#{token}")
    assert html =~ ~s(phx-click="read-conversation")
    assert html =~ "Open chat for acme/aiur #1110"
    refute html =~ "Conversation unavailable"
    refute html =~ handle
  end
end
