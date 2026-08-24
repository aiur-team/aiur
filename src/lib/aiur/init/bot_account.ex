defmodule Aiur.Init.BotAccount do
  @moduledoc """
  Bot-account step for the GitHub `aiur init` wizard — explains the difference
  between the `GITHUB_TOKEN` credential and the `github.bot_account` identity,
  then asks which login Aiur's agents post as, defaulting to the login the
  configured token authenticates as (the validated viewer-identity path).

  The answer is normalized, validated as a GitHub login, and merged into the
  tracker map as `:bot_account` so the config template persists it under
  `tracker.github.bot_account`. A blank answer skips it (nothing written); a
  malformed typed answer re-prompts. No token value is ever shown or written.

  Non-interactive / `--force` runs are deterministic: the injected prompt echoes
  the default, so setup applies the detected token login when one is resolved and
  omits the key otherwise — the loop never blocks, since an unresolved or invalid
  default is sanitized to nil (skip). Re-running init resumes and never rewrites
  the tracker, so an existing `bot_account` is preserved.
  """

  alias Aiur.Codeowners.Edit
  alias Aiur.Init.Format

  # GitHub login: 1–39 chars, alphanumeric with single internal hyphens, never
  # leading/trailing hyphen. Matched after `Edit.normalize_login/1` lowercases.
  #
  # The optional `[bot]` suffix is the GitHub App bot form (`<app-slug>[bot]`),
  # which is the correct bot_account whenever the daemon authenticates with a
  # GitHub App installation token (see docs/security/daemon-token-posture.md).
  # Without it the wizard rejects the very login App auth requires, and a
  # non-interactive run degrades that default to nil — leaving self-loop
  # suppression off.
  @login_regex ~r/^[a-z\d](?:-?[a-z\d])*(?:\[bot\])?$/
  @bot_suffix "[bot]"
  @max_login_length 39

  @prompt_label "GitHub account Aiur's agents post as (bot_account)"

  @prompt_hint "The login Aiur recognizes as its own to suppress self-triggered comment/event loops. Under GitHub App auth this is the App bot login, `<app-slug>[bot]`."

  @doc """
  Prompts for and returns the tracker with `:bot_account` filled for a GitHub
  tracker; passes any other tracker through unchanged.
  """
  @spec maybe_prompt(Aiur.Init.io(), Aiur.Init.deps(), map()) :: map()
  def maybe_prompt(io, deps, %{kind: "github"} = tracker) do
    explain(io)
    # Sanitize the detected default here so the prompt loop's termination never
    # depends on the resolver only ever returning a valid login or nil: a
    # non-interactive run echoes the default, so an invalid default must degrade
    # to nil (skip) rather than re-prompt forever.
    default = valid_login_or_nil(Edit.normalize_login(deps.github_bot_account_default.()))
    Map.put(tracker, :bot_account, prompt(io, default))
  end

  def maybe_prompt(_io, _deps, tracker), do: tracker

  defp explain(io) do
    io.puts.([
      "\nAiur separates two GitHub identities:\n",
      "  • GITHUB_TOKEN — the credential used for GitHub API and `gh` operations.\n",
      "    Agents do not inherit it: the daemon writes it to the `gh` guard's file and\n",
      "    injects it only for the duration of a governed call (#2356).\n",
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
        if valid_login?(login) do
          login
        else
          io.puts.("Enter a valid GitHub login (letters, numbers, and single hyphens), or a GitHub App bot login like `my-app[bot]`.")
          prompt(io, default)
        end
    end
  end

  @spec valid_login_or_nil(String.t() | nil) :: String.t() | nil
  defp valid_login_or_nil(login) when is_binary(login), do: if(valid_login?(login), do: login)
  defp valid_login_or_nil(_login), do: nil

  # GitHub logins are ≤ 39 chars; the regex already bounds shape. Assumes a
  # login normalized by `Edit.normalize_login/1` (trimmed, lowercased, no `@`).
  # The `[bot]` suffix is GitHub's own decoration on top of the App slug, so it
  # is measured outside the 39-character login budget.
  @spec valid_login?(String.t()) :: boolean()
  defp valid_login?(login) do
    slug = String.replace_suffix(login, @bot_suffix, "")

    String.length(slug) <= @max_login_length and Regex.match?(@login_regex, login)
  end
end
