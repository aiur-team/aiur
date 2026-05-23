defmodule Aiur.Regression.ChatPaneLoadsSessionTest do
  @moduledoc """
  Regression for "chat pane shows OPENCODE welcome screen instead of
  agent conversation" (reported 2026-05-21).

  Root cause: opencode 1.15.6's TUI does NOT switch the rendered view
  in response to `POST /tui/select-session` once attach has rendered
  its welcome screen. The session is loaded server-side (visible via
  `GET /session/<id>/message`) but the TUI stays on the OPENCODE logo
  + "Ask anything..." prompt. The reliable workaround is to (re)spawn
  `opencode attach <url> --session <session_id>` so the TUI boots
  straight into the conversation view.

  Manual verification: open agent N's chat in a fresh aiur, confirm
  pane shows message turns (e.g. `▣  Build · issue-N · 123ms` lines)
  not the welcome screen. This automated check guards the WIRING that
  makes that work — the Slot's :select path MUST spawn attach with
  a `--session` flag, not just POST `/tui/select-session`.
  """

  use ExUnit.Case, async: true

  alias Aiur.Opencode.Protocol

  describe "Protocol.attach_command/2 (session-bound attach)" do
    test "includes the --session flag with the session id" do
      cmd = Protocol.attach_command("http://127.0.0.1:1234", "ses_abc123")

      assert cmd =~ "--session",
             "attach_command/2 MUST include --session so opencode-attach boots into the conversation"

      assert cmd =~ "ses_abc123",
             "attach_command/2 MUST include the session id verbatim"

      assert cmd =~ "attach"
    end

    test "shell-escapes session ids that contain unsafe characters" do
      assert Protocol.attach_command("http://x", "ses one") =~ "'ses one'"
    end
  end

  describe "Protocol.attach_command/1 (no session)" do
    test "produces a no-session attach for the slot pre-warm path" do
      cmd = Protocol.attach_command("http://127.0.0.1:1234")

      refute cmd =~ "--session",
             "attach_command/1 must NOT include --session — it is the pre-warm command before any agent is selected"
    end
  end

  describe "Slot uses session-bound attach for :select" do
    @slot_source Path.expand("../../../lib/aiur/opencode/slot.ex", __DIR__)

    test "do_select spawns a fresh attach pane bound to the session_id for cold opens" do
      source = File.read!(@slot_source)

      assert source =~ ~r/Protocol\.attach_command\(\s*state\.base_url\s*,\s*session_id\s*\)/,
             "Slot MUST retain Protocol.attach_command/2 so welcome→conversation transitions use --session"
    end

    test "API select_session is gated on an already-painted conversation pane" do
      source = File.read!(@slot_source)

      assert source =~ ~r/can_select_via_api\?/,
             "Slot MUST gate ApiClient.select_session behind a predicate that requires an already-painted conversation pane (visible_identifier set, pane_id set)"

      assert source =~ ~r/visible_identifier != identifier/,
             "the API fast-path predicate MUST require the swap to be conversation→different-conversation"
    end
  end
end
