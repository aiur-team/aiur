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

    test "do_select spawns a fresh attach pane bound to the session_id" do
      # Read the slot source and assert the wiring: do_select must
      # respawn attach with the 2-arity `Protocol.attach_command(url, sid)`.
      # If a future refactor reverts to just POSTing /tui/select-session
      # (which silently fails to render in opencode 1.15.6), this test
      # turns red and the user sees the welcome screen.
      source = File.read!(@slot_source)

      assert source =~ ~r/Protocol\.attach_command\(\s*state\.base_url\s*,\s*session_id\s*\)/,
             "Slot.do_select MUST call Protocol.attach_command/2 with session_id — POSTing /tui/select-session alone does NOT switch the TUI view in opencode 1.15.6"

      refute source =~ ~r/ApiClient\.select_session\b/,
             "Slot must not rely on POST /tui/select-session as the session-attach mechanism — opencode 1.15.6's TUI does not honor it after the welcome screen is rendered"
    end
  end
end
