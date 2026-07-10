defmodule Aiur.Opencode.OperatorText do
  @moduledoc """
  Pure opencode `<system-reminder>` operator-wrapper wire shape.

  Extracts every wrapped operator message from an opencode-formatted payload
  (`normalize/1`) and derives the greppable `wrapped`/`dropped` trace fields
  used to detect the #332 silent-drop bug signature (`trace/2`).

  Sibling of `Aiur.Opencode.Protocol` in the wire-shape isolation boundary.
  No side effects; no process interaction.
  """

  # Opencode wraps operator-typed text in `<system-reminder>` envelopes before
  # POSTing it to the bridge (confirmed verbatim in the opencode 1.15.6 binary:
  # `["<system-reminder>","The user sent the following message:",text,"",
  # "Please address this message and continue with your tasks.",
  # "</system-reminder>"].join("\n")`, applied per user text part in place).
  # The "...Please address this message and continue with your tasks" tail
  # buries the message and makes the agent keep working instead of answering,
  # so we forward only the operator's genuine text — exactly what Claude's
  # Remote Control channel delivers — and opencode input is consumed like RC.
  #
  # opencode 1.17.10 (the pinned version) no longer emits this user-message
  # wrapper (verified absent from the binary): the scan below then finds no
  # match and the generic system-reminder strip + raw passthrough branches
  # carry the operator's text. The extraction is kept because it stays correct
  # for any opencode that still wraps and guards the #332 silent drop.
  #
  # The pattern is intentionally NOT `\A..\z`-anchored: opencode also emits its
  # own `<system-reminder>` scaffolding (cwd/file/selection/goal) and can fold
  # several queued messages into one batch, so a real payload carries the
  # wrapper concatenated with — or surrounded by — other content. An anchored
  # match missed those, fell through to the generic strip below, and that strip
  # deleted the operator-bearing block too, yielding "" — a silent drop the
  # agent could never answer (issue #332). Scanning every wrapper anywhere in
  # the text recovers the operator's message regardless of what surrounds it.
  # Line breaks are `\r?\n` so a CRLF payload can't slip past the match and hit
  # the over-deleting strip (the primary path pre-strips CR in `validate_body`,
  # but this keeps the extraction correct independent of its callers).
  @operator_wrapper_regex ~r/<system-reminder>\r?\nThe user sent the following message:\r?\n(?<msg>[\s\S]*?)\r?\n\r?\nPlease address this message and continue with your tasks\.\r?\n<\/system-reminder>/

  @doc false
  # Pure derivation of the operator-path trace fields, so the diagnostic
  # contract is unit-testable without Plug/app scaffolding. `wrapped` is true
  # only when a genuine, non-blank operator message was buried in an opencode
  # wrapper — an empty-bodied wrapper or scaffolding-only reminder is not a
  # message and must not trip the alarm. `dropped` then means exactly "a real
  # operator message was present but nothing was forwarded." Both fields and
  # `normalize/1` derive from the same `scan_operator_messages/1`,
  # so the signal can't silently desync from what was actually delivered.
  @spec trace(String.t(), String.t()) :: %{
          in_bytes: non_neg_integer(),
          out_bytes: non_neg_integer(),
          wrapped: boolean(),
          dropped: boolean()
        }
  def trace(raw, normalized) when is_binary(raw) and is_binary(normalized) do
    wrapped? =
      case scan_operator_messages(raw) do
        nil -> false
        msgs -> Enum.any?(msgs, &(String.trim(&1) != ""))
      end

    %{
      in_bytes: byte_size(raw),
      out_bytes: byte_size(normalized),
      wrapped: wrapped?,
      dropped: wrapped? and normalized == ""
    }
  end

  @doc false
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    cond do
      msgs = scan_operator_messages(text) ->
        # One or more operator messages buried in opencode wrappers (a folded
        # batch arrives as several concatenated wrappers). Recover and trim
        # each, joined by a newline.
        Enum.map_join(msgs, "\n", &String.trim/1)

      String.contains?(text, "<system-reminder>") ->
        # No operator-bearing wrapper, only opencode scaffolding — strip it.
        # Pure scaffolding normalizes to "" and `send_operator/3` noops it.
        text
        |> String.replace(~r/<system-reminder>[\s\S]*?<\/system-reminder>/, "")
        |> String.trim()

      true ->
        text
    end
  end

  # Every operator message buried in an opencode mid-stream wrapper, in order.
  # `nil` (not `[]`) when none match so the `cond` falls through cleanly.
  defp scan_operator_messages(text) do
    case Regex.scan(@operator_wrapper_regex, text, capture: ["msg"]) do
      [] -> nil
      matches -> Enum.map(matches, fn [msg] -> msg end)
    end
  end
end
