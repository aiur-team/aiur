defmodule Aiur.Claude.Repl.RcAttach do
  @moduledoc """
  RC attach evidence and URL harvest.

  Scans the just-ready pane for the Remote Control session URL. The session URL
  is a capability token — never logged.

  RC-attach evidence takes one of two on-pane forms:
    * banner form: a `/remote-control is active · … https://claude.ai/code/session_…`
      banner prints into the pane — the URL is right there.
    * footer form: only a small `/rc active` indicator shows. Harvest the URL by
      running the `/rc` slash command, whose dialog prints the URL, then dismiss
      it with Esc.
  """

  alias Aiur.Claude.RemoteControl
  alias Aiur.Tmux

  # When launched with `--remote-control`, the REPL prints a
  # `… https://claude.ai/code/session_… ` banner to the pane as it attaches,
  # alongside the ready prompt. Scan the pane for it once the REPL is ready;
  # it is a capability token surfaced only to the operator display, never
  # logged. The banner is also the proof RC attached: an account without RC
  # entitlement never prints it, so its absence within this budget is taken
  # as RC-unavailable and degrades the session to the non-RC backend (see
  # `build_ready_session/3`). The window is generous so a slow-but-working
  # attach is never mistaken for an unavailable one.
  @url_capture_timeout_ms 10_000
  @url_poll_ms 150

  # Type `/rc`, submit, scrape the dialog for the session URL, and ALWAYS
  # dismiss with Esc so the dialog can't eat the first prompt's keystrokes.
  # A short dedicated budget: the dialog renders locally (no network wait).
  @rc_dialog_timeout_ms 5_000

  # Scan the just-ready pane for the Remote Control session URL. Polls until
  # the banner lands or the budget elapses — it can appear a beat after the
  # prompt. Returns nil when it never appears; for an RC session that nil is
  # the RC-unavailable signal (see `Launcher.build_ready_session/3`).
  @spec capture_session_url(GenServer.server(), String.t(), keyword()) :: String.t() | nil
  def capture_session_url(tmux, pane_id, opts) do
    timeout = Keyword.get(opts, :url_capture_timeout_ms, @url_capture_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout

    case poll_rc_evidence(tmux, pane_id, deadline) do
      {:url, url} -> url
      :rc_active -> harvest_url_via_rc_command(tmux, pane_id)
      :none -> nil
    end
  end

  defp poll_rc_evidence(tmux, pane_id, deadline) do
    text =
      case Tmux.capture_pane(tmux, pane_id) do
        {:ok, lines} -> Enum.join(lines, "\n")
        _ -> ""
      end

    cond do
      url = RemoteControl.parse_session_url(text) ->
        {:url, url}

      String.contains?(text, "/rc active") ->
        :rc_active

      System.monotonic_time(:millisecond) >= deadline ->
        :none

      true ->
        Process.sleep(@url_poll_ms)
        poll_rc_evidence(tmux, pane_id, deadline)
    end
  end

  defp harvest_url_via_rc_command(tmux, pane_id) do
    url =
      with :ok <- Tmux.send_keys_literal(tmux, pane_id, "/rc"),
           :ok <- Tmux.send_enter(tmux, pane_id) do
        dialog_deadline = System.monotonic_time(:millisecond) + @rc_dialog_timeout_ms
        do_capture_session_url(tmux, pane_id, dialog_deadline)
      else
        _ -> nil
      end

    _ = Tmux.send_escape(tmux, pane_id)
    url
  end

  defp do_capture_session_url(tmux, pane_id, deadline) do
    url =
      case Tmux.capture_pane(tmux, pane_id) do
        {:ok, lines} -> lines |> Enum.join("\n") |> RemoteControl.parse_session_url()
        _ -> nil
      end

    cond do
      is_binary(url) ->
        url

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(@url_poll_ms)
        do_capture_session_url(tmux, pane_id, deadline)
    end
  end
end
