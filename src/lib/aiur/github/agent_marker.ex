defmodule Aiur.GitHub.AgentMarker do
  @moduledoc """
  The durable, in-body provenance marker Aiur stamps on comments it authors,
  and the only thing that may answer "did Aiur write this comment?" when the
  agents and the human operator share one GitHub login (single-account mode).

  ## Why the body and not the login

  Separate-account mode answers authorship from the author login, which is
  sound because only Aiur holds that login. Single-account mode removes that
  premise: the operator's own comments carry the same login as the agents', so
  a login-keyed gate must either drop both (the operator can never reach an
  agent) or pass both (agents answer themselves forever). Neither is
  acceptable, so discrimination has to key on something Aiur controls about the
  comment **it wrote**. An HTML comment is that thing: GitHub stores it
  verbatim in the comment body, returns it verbatim over the API, and renders
  it to nothing, so it is invisible to a reader and exact to match.

  ## The failure direction is chosen, not incidental

  Authorship is decided by the **presence** of the marker, never by its
  absence. A missing, truncated, or unreadable marker resolves to "a human
  wrote this", which costs at most one extra agent wake. The opposite default —
  reading an unmarked comment as Aiur's own — would silently swallow operator
  instructions, and the same shape (inferring a fact from an absence) is what
  produced #2478 and #2498. It follows that every comment posted before this
  landed reads as human, which is the correct reading of a comment nothing can
  prove Aiur wrote.

  The marker is a fixed literal rather than a per-comment nonce so that it
  survives a daemon restart, a rebuilt release, and an agent process the daemon
  never observed, none of which can be said for a table of comment ids. It
  proves "Aiur authored this", not "this specific run authored this"; nothing
  in the wake path needs the stronger claim.
  """

  alias Aiur.GitHub.Config

  @marker "<!-- aiur:agent-authored -->"

  @doc """
  The literal marker. Stable across releases: changing it re-classifies every
  already-posted agent comment as human.
  """
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Name of the environment variable through which the daemon hands the marker to
  the agent-side `gh` guard. Unset means "do not stamp", which is exactly the
  separate-account default.
  """
  @spec env_var() :: String.t()
  def env_var, do: "AIUR_AGENT_COMMENT_MARKER"

  @doc """
  Append the marker to a comment body Aiur is about to post, when the install
  is in single-account mode. Separate-account installs are returned unchanged,
  so no comment body anywhere is altered by adopting this module alone.

  Idempotent: a body that already carries the marker is returned as-is, so an
  edit that reposts an existing body does not accumulate markers.
  """
  @spec stamp(String.t()) :: String.t()
  def stamp(body) when is_binary(body) do
    cond do
      not Config.single_account?() -> body
      marked?(body) -> body
      true -> String.trim_trailing(body) <> "\n\n" <> @marker
    end
  end

  @doc """
  Whether a comment body carries the marker *as its own trailing line*.
  `false` for anything that is not a binary — an unreadable body is a body that
  cannot prove Aiur wrote it.

  Position matters, and an unscoped `String.contains?/2` is wrong here.
  GitHub's "Quote reply" copies the quoted comment verbatim, HTML comments
  included, so a human quoting an agent in order to correct it would inherit
  the agent's marker and have their correction read as Aiur's own — a swallowed
  instruction, and quoting to disagree is the ordinary review gesture.

  Two rules close that, matching how `stamp/1` writes the marker:

    * Blockquote lines are dropped first, so a marker that arrived inside a
      `>` quotation never counts.
    * The marker must then be the last thing in the body. A human writing below
      a quotation therefore reads as human, which is the whole point.

  Both rules only ever move a body from "ours" to "human", so the safe failure
  direction is preserved.
  """
  @spec marked?(term()) :: boolean()
  def marked?(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&quoted_line?/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> String.ends_with?(@marker)
  end

  def marked?(_body), do: false

  defp quoted_line?(line), do: line |> String.trim_leading() |> String.starts_with?(">")
end
