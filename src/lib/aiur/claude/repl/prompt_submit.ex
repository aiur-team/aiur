defmodule Aiur.Claude.Repl.PromptSubmit do
  @moduledoc """
  Both prompt-delivery protocols, side by side, NEVER unified.

  The two protocols are deliberately different and must never be DRY-merged —
  merging reintroduces the #373/#374 paste race and the respawn loop.

  - `submit/3` — Hook/RC protocol: paste → wait read-only for the paste to land
    → Enter. It NEVER clears/retypes and never fails on echo timeout — Enter still
    fires best-effort and the UserPromptSubmit hook confirms receipt.

  - `send/3` — Transcript protocol: confirm the echo (clear + re-paste retry) before
    Enter; fail loudly with `{:error, :prompt_not_delivered}` rather than ever
    submitting a blank line.
  """

  alias Aiur.Tmux

  # The REPL renders its prompt glyph (`@ready_prompt`) before it actually
  # accepts input — and a `--remote-control` session lags further while it
  # connects — so the first paste is routinely dropped. Delivery is only safe
  # once the prompt lands in the input buffer, so we keep re-pasting (clearing
  # the line first) on `@echo_retype_ms` until the buffer confirms it or
  # `@echo_confirm_ms` elapses; only then does Enter submit. Without this,
  # Enter submits a blank line and the turn silently does nothing, the
  # transcript never appears, and the run fails `:no_transcript`.
  @echo_confirm_ms 20_000
  @echo_retype_ms 1_500
  @echo_poll_ms 100

  # A multi-line prompt is delivered as a bracketed paste, which the REPL
  # renders as a collapsed `[Pasted text +N lines]` chip rather than echoing
  # the literal text — so the buffer-landed check matches this chip as well as
  # a verbatim prefix (short single-line prompts still echo literally).
  @paste_indicator "[Pasted text"

  # Hook-driven (RC) submit: paste the prompt, wait for it to land in the input
  # box, then Enter. The wait is load-bearing — a large multi-line paste-buffer
  # needs a beat before claude's TUI will accept Enter as a submit, so firing
  # Enter immediately races the paste and leaves the prompt sitting unsubmitted
  # (claude never starts a turn, no hooks fire). Unlike confirm_typed this never
  # clears/retypes (that C-u reads as an interrupt that cancels a live turn) and
  # never fails the run: if the paste does not echo within the budget (claude
  # folded it into its native queue mid-turn, clearing the input box), Enter
  # still fires best-effort and the UserPromptSubmit hook confirms receipt.
  @spec submit(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def submit(session, prompt, opts) do
    with :ok <- Tmux.paste_text(session.tmux, session.pane_id, prompt) do
      _ = await_paste_landed(session, prompt, opts)
      Tmux.send_enter(session.tmux, session.pane_id)
    end
  end

  # Poll the input buffer (read-only — no clear, no retype) until the paste
  # lands as the `[Pasted text` chip or the prompt prefix, so Enter submits it
  # instead of racing the paste-buffer. Best-effort: returns `:timeout` once the
  # budget elapses rather than erroring, so a mid-turn fold (no chip) still
  # falls through to a harmless Enter + hook-confirmed receipt.
  defp await_paste_landed(session, prompt, opts) do
    confirm_ms = Keyword.get(opts, :prompt_confirm_ms, @echo_confirm_ms)
    prefix = echo_prefix(prompt)
    deadline = System.monotonic_time(:millisecond) + confirm_ms
    poll_paste_landed(session, prefix, deadline)
  end

  defp poll_paste_landed(session, prefix, deadline) do
    cond do
      input_echoes?(session, prefix) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(@echo_poll_ms)
        poll_paste_landed(session, prefix, deadline)
    end
  end

  # Only submit (Enter) once the typed prompt has actually echoed into the
  # input buffer; a dropped send must never be committed as a blank line.
  @spec send(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def send(session, prompt, opts) do
    case confirm_typed(session, prompt, opts) do
      :ok -> Tmux.send_enter(session.tmux, session.pane_id)
      {:error, reason} -> {:error, reason}
    end
  end

  # Paste the prompt, then poll the input buffer until it lands. The REPL
  # renders its glyph before it accepts input (and an RC session lags
  # further), so the first paste is routinely dropped — keep clearing the line
  # and re-pasting on `retype_ms` until the buffer reflects it. Fail loudly
  # with `:prompt_not_delivered` if the budget elapses with nothing landed,
  # rather than submitting a blank line. Reads the pane only to confirm input
  # (not output).
  defp confirm_typed(session, prompt, opts) do
    confirm_ms = Keyword.get(opts, :prompt_confirm_ms, @echo_confirm_ms)
    retype_ms = Keyword.get(opts, :prompt_retype_ms, @echo_retype_ms)
    prefix = echo_prefix(prompt)
    Tmux.paste_text(session.tmux, session.pane_id, prompt)
    now = System.monotonic_time(:millisecond)
    poll_echo(session, prompt, prefix, confirm_ms, retype_ms, now, now)
  end

  defp poll_echo(session, prompt, prefix, confirm_ms, retype_ms, start, last_retype) do
    elapsed = System.monotonic_time(:millisecond) - start

    cond do
      input_echoes?(session, prefix) ->
        :ok

      elapsed >= confirm_ms ->
        {:error, :prompt_not_delivered}

      System.monotonic_time(:millisecond) - last_retype >= retype_ms ->
        # The paste was dropped (glyph showed before the REPL was live);
        # clear any partial buffer and re-paste now that it may be ready.
        Tmux.clear_input(session.tmux, session.pane_id)
        Tmux.paste_text(session.tmux, session.pane_id, prompt)
        Process.sleep(@echo_poll_ms)
        now = System.monotonic_time(:millisecond)
        poll_echo(session, prompt, prefix, confirm_ms, retype_ms, start, now)

      true ->
        Process.sleep(@echo_poll_ms)
        poll_echo(session, prompt, prefix, confirm_ms, retype_ms, start, last_retype)
    end
  end

  defp input_echoes?(session, prefix) do
    case Tmux.capture_pane(session.tmux, session.pane_id) do
      {:ok, lines} ->
        joined = Enum.join(lines, "\n")
        String.contains?(joined, prefix) or String.contains?(joined, @paste_indicator)

      _ ->
        false
    end
  end

  defp echo_prefix(prompt) do
    prompt |> String.trim() |> String.slice(0, 24)
  end
end
