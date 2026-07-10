defmodule Aiur.Regression.EnterOpensNewPaneTest do
  @moduledoc """
  Regression for "non-first agent chat panes open for a split second
  then crash" (reported 2026-05-23 on branch updated-opencode-logic).

  Root cause was layered:

    1. `SessionWriterRegistry` cached one writer per identifier,
       returning a session_id created against the FIRST slot's serve
       for any subsequent slot that attached the same identifier.
       That session_id was not loadable in the other slots' serves,
       so opencode-attach launched against a phantom session and
       failed to paint / died on first interaction.

    2. Pressing Enter on a different agent routed through
       `Slot.select` → `do_select_via_api` → `POST /tui/select-session`,
       which opencode 1.15.6 returns 200 to but then exits the attach
       process 1.5-25 s later, killing the user's chat pane.

  Fix: register per `(identifier, base_url)`, remove
  `/tui/select-session` entirely, and route plain Enter through the
  same `:new_pane` path as Shift+Enter so the user always gets a
  pre-warmed slot's pane moved-visible (instant) rather than an
  in-place session swap.
  """

  use ExUnit.Case, async: true

  @app_source Path.expand("../../../lib/aiur/agent_list/app.ex", __DIR__)
  @slot_source Path.expand("../../../lib/aiur/opencode/slot.ex", __DIR__)
  @registry_source Path.expand(
                     "../../../lib/aiur/opencode/session_writer_registry.ex",
                     __DIR__
                   )
  @opencode_open_source Path.expand("../../../lib/aiur/pane_manager/opencode_open.ex", __DIR__)

  describe "AgentList Enter behavior" do
    test "plain Enter dispatches :new_pane (not :swap_in_last_used)" do
      source = File.read!(@app_source)

      activate_block =
        source
        |> String.split(~r/def handle_cast\(:activate, state\) do/, parts: 2)
        |> List.last()
        |> String.split(~r/def handle_cast\(:/, parts: 2)
        |> List.first()

      assert activate_block =~ ":new_pane",
             "handle_cast(:activate, ...) MUST dispatch :new_pane. The previous :swap_in_last_used path called /tui/select-session which kills the chat pane in opencode 1.15.6."

      refute activate_block =~ ":swap_in_last_used",
             "Plain Enter must not dispatch :swap_in_last_used. Swap-in-place is structurally unreachable from user input now."
    end

    test "Shift+Enter still dispatches :new_pane" do
      source = File.read!(@app_source)
      assert source =~ ~r/handle_cast\(:activate_new_pane, state\)/
    end
  end

  describe "Slot has no /tui/select-session call site" do
    test "do_select_via_api and can_select_via_api are gone" do
      source = File.read!(@slot_source)

      refute source =~ "do_select_via_api"
      refute source =~ "can_select_via_api"
    end

    test "no leaf reference to ApiClient.select_session in slot.ex" do
      source = File.read!(@slot_source)
      refute source =~ ~r/ApiClient\.select_session/
    end
  end

  describe "SessionWriterRegistry is keyed per (identifier, base_url)" do
    test "registry uses :duplicate keys" do
      app_source = File.read!(Path.expand("../../../lib/aiur.ex", __DIR__))

      assert app_source =~
               ~r/keys:\s*:duplicate.*Aiur\.Opencode\.SessionWriterRegistry\.Registry/,
             "SessionWriterRegistry.Registry MUST allow duplicate keys so each slot's serve can register its own writer for the same identifier without the first writer winning permanently."
    end

    test "ensure/2 looks up by both identifier and base_url" do
      source = File.read!(@registry_source)

      assert source =~ ~r/lookup\(identifier, base_url\)/,
             "ensure/2 MUST consult lookup/2 (identifier, base_url) so each slot's serve gets its OWN session_id rather than reusing the first slot's."
    end
  end

  describe "PaneManager warm-open hot path is lock-free" do
    test "open_opencode_pane checks SlotRegistry.find_visible BEFORE AttachPool.consume" do
      source = File.read!(@opencode_open_source)

      open_block =
        source
        |> String.split(~r/def open_opencode_pane\(state, identifier, _opts, from\) do/, parts: 2)
        |> List.last()
        |> String.split(~r/def move_warm_pane_visible/, parts: 2)
        |> List.first()

      assert open_block =~ "SlotRegistry.find_visible",
             "open_opencode_pane MUST check SlotRegistry.find_visible/1 first — a lock-free ETS read that bypasses Slot and AttachPool mailbox latency. Without this, the warm path is gated on AttachPool.consume (a GenServer.call that itself calls Slot.set_visible), and a busy fan-out wedges both for >5 s, timing the user-facing open into the cold placeholder path."

      registry_pos =
        open_block
        |> String.split("SlotRegistry.find_visible", parts: 2)
        |> List.first()
        |> String.length()

      consume_pos =
        case String.split(open_block, "AttachPool.consume", parts: 2) do
          [before, _after] -> String.length(before)
          _ -> nil
        end

      assert is_integer(consume_pos),
             "open_opencode_pane MUST retain AttachPool.consume as the fallback for slots that have the identifier ATTACHED but not yet PAINTED as their visible leadoff."

      assert registry_pos < consume_pos,
             "SlotRegistry.find_visible MUST be checked BEFORE AttachPool.consume so the warm path never blocks on a busy GenServer mailbox."
    end
  end

  describe "Slot mirrors visible state into SlotRegistry" do
    test "broadcast_visible_changed publishes pane_id into SlotRegistry" do
      source = File.read!(@slot_source)

      helper_block =
        source
        |> String.split(~r/defp broadcast_visible_changed\(/, parts: 2)
        |> List.last()
        |> String.split(~r/defp [a-z_]+/, parts: 2)
        |> List.first()

      assert helper_block =~ "SlotRegistry.update_pane_state",
             "broadcast_visible_changed MUST call SlotRegistry.update_pane_state so the lock-free warm-open lookup in PaneManager sees the current {visible_identifier, pane_id} for this slot. Without this, find_visible always returns :not_found and the hot path falls through to the slow consume."
    end
  end
end
