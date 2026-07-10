defmodule Aiur.Claude.Repl.OperatorInject do
  @moduledoc """
  Operator input into the live REPL pane.

  Provides mid-turn delivery of operator messages and the explicit interrupt
  path. PTY input is sanitized: every control byte collapses to a space so a
  crafted message cannot submit early or inject escape codes.
  """

  require Logger

  alias Aiur.Tmux

  @doc """
  Inject an operator message straight into the live REPL pane.

  This is the whole of mid-turn delivery: sanitize the text, type it with
  `send_keys_literal`, then submit with one `Enter`. The agent's native
  input queue does the rest — it folds the message in at the next natural
  boundary without aborting in-flight work, so there is no bespoke
  interrupt-then-send path here (cutting the agent off is a separate,
  explicit parity action, not this one).

  Operator text is typed verbatim into a PTY, so it is sanitized first:
  every control byte (newlines that would submit early, `Esc`/C0/C1
  sequences that would trip the REPL's own keybindings) is collapsed to a
  space. The single trailing `Enter` is the only submit.
  """
  @spec send_operator_message(map(), Aiur.CodingAgent.operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(%{tmux: tmux, pane_id: pane_id}, %{kind: :text, body: body})
      when is_binary(body) do
    case sanitize_pane_input(body) do
      "" ->
        {:error, :empty_message}

      text ->
        with :ok <- Tmux.send_keys_literal(tmux, pane_id, text),
             :ok <- Tmux.send_enter(tmux, pane_id) do
          {:ok, System.unique_integer([:positive])}
        end
    end
  end

  def send_operator_message(_session, _payload), do: {:error, :invalid_message}

  @doc """
  Interrupt the REPL's current turn by sending `Ctrl+C` to its pane.

  This is the explicit operator-interrupt path: unlike
  `send_operator_message/2`, which lets Claude's native queue fold a
  message in at the next boundary without aborting in-flight work, this
  cuts the active turn at Claude's next safe point so a queued message is
  drained immediately.
  """
  # Accepts any map carrying :tmux + a binary :pane_id — callers like the
  # orchestrator's pane-interrupt path build a minimal `%{tmux:, pane_id:}`
  # rather than threading a full session().
  @spec interrupt(map()) :: :ok | {:error, term()}
  def interrupt(%{tmux: tmux, pane_id: pane_id}) when is_binary(pane_id) do
    Tmux.send_interrupt(tmux, pane_id)
  end

  def interrupt(_session), do: {:error, :invalid_session}

  @doc """
  Deliver an operator message from the native queue into the live pane.

  The claim callback (supplied by the runner) talks to the orchestrator
  queue and hands back the operator text plus consume/restore callbacks,
  so the driver stays decoupled from the queue store. `:noop` means
  nothing was claimable (e.g. a racing drain already took it).
  """
  @spec deliver_immediate_operator_message(map(), function()) :: :ok
  def deliver_immediate_operator_message(session, on_operator) do
    case on_operator.() do
      {:deliver_text, text, on_success, on_failure}
      when is_binary(text) and is_function(on_success, 1) and is_function(on_failure, 1) ->
        case send_operator_message(session, %{kind: :text, body: text}) do
          {:ok, request_id} ->
            Logger.info("repl_operator_delivered bytes=#{byte_size(text)} pane=#{session.pane_id}")
            on_success.(%{request_id: request_id})

          {:error, reason} ->
            Logger.warning("repl_operator_deliver_failed reason=#{inspect(reason)}")
            on_failure.(reason)
        end

      :noop ->
        # The queue update fired but nothing was claimable (e.g. the claim call
        # to the orchestrator returned :empty/timeout under load). Surfacing this
        # distinguishes "never reached the loop" from "claim came back empty".
        Logger.info("repl_operator_deliver_noop pane=#{session.pane_id}")
        :ok
    end
  end

  # Operator content is typed into a live PTY via `send-keys -l`, which
  # emits the bytes verbatim. Collapse every control byte to a space so a
  # crafted message cannot submit early (embedded newline), abort the agent
  # (`Esc`), or inject terminal escape codes / extra keystrokes. The one
  # explicit `Enter` in send_operator_message/2 is the only submit.
  defp sanitize_pane_input(body) do
    body
    |> String.replace(~r/[\x00-\x1f\x7f]/, " ")
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
  end
end
