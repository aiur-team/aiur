defmodule Aiur.Init.BotAccount do
  @moduledoc """
  Bot-account step for the GitHub `aiur init` wizard — explains the difference
  between the `GITHUB_TOKEN` credential and the `github.bot_account` identity,
  then asks which login Aiur's agents post as, defaulting to the login the
  configured token authenticates as (the validated viewer-identity path).

  The answer is normalized, validated as a GitHub login, and merged into the
  tracker map as `:bot_account` so the config template persists it under
  `tracker.github.bot_account`. A blank answer skips it (nothing written); a
  malformed login re-prompts. No token value is ever shown or written.
  """

  alias Aiur.Codeowners.Edit
  alias Aiur.Init.Format

  # GitHub login: 1–39 chars, alphanumeric with single internal hyphens, never
  # leading/trailing hyphen. Matched after `Edit.normalize_login/1` lowercases.
  @login_regex ~r/^[a-z\d](?:-?[a-z\d])*$/

  @prompt_label "GitHub account Aiur's agents post as (bot_account)"

  @prompt_hint "The login Aiur recognizes as its own to suppress self-triggered comment/event loops."

  @doc """
  Prompts for and returns the tracker with `:bot_account` filled for a GitHub
  tracker; passes any other tracker through unchanged.
  """
  @spec maybe_prompt(Aiur.Init.io(), Aiur.Init.deps(), map()) :: map()
  def maybe_prompt(io, deps, %{kind: "github"} = tracker) do
    explain(io)
    default = Edit.normalize_login(deps.github_bot_account_default.())
    Map.put(tracker, :bot_account, prompt(io, default))
  end

  def maybe_prompt(_io, _deps, tracker), do: tracker

  defp explain(io) do
    io.puts.([
      "\nAiur separates two GitHub identities:\n",
      "  • GITHUB_TOKEN — the credential used for GitHub API and inherited `gh` operations.\n",
      "  • github.bot_account — the login Aiur uses to recognize and suppress its own\n",
      "    comment/event loops (so an agent's own reply is never treated as human feedback).\n",
      "A dedicated bot account is recommended when operators also comment from a trusted\n",
      "CODEOWNER account. Reusing one login for agents and humans makes provenance\n",
      "ambiguous and may require the stronger origin tracking tracked in #1151."
    ])
  end

  @spec prompt(Aiur.Init.io(), String.t() | nil) :: String.t() | nil
  defp prompt(io, default) do
    case Edit.normalize_login(io.input.(@prompt_label, default, @prompt_hint)) do
      nil ->
        io.puts.(Format.dim("Skipped bot_account. Set tracker.github.bot_account later to suppress agent self-loops."))
        nil

      login ->
        if Regex.match?(@login_regex, login) and String.length(login) <= 39 do
          login
        else
          io.puts.("Enter a valid GitHub login (letters, numbers, and single hyphens).")
          prompt(io, default)
        end
    end
  end
end
