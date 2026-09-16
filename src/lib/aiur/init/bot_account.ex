defmodule Aiur.Init.BotAccount do
  @moduledoc """
  GitHub identity step for the `aiur init` wizard. It asks once whether agents
  post as the operator or a separate bot, then derives the configured identities
  from that explicit choice.

  The answer is normalized, validated as a GitHub login, and merged into the
  tracker map as `:bot_account` so the config template persists it under
  `tracker.github.bot_account`. A blank answer skips it (nothing written); a
  malformed typed answer re-prompts. No token value is ever shown or written.

  Non-interactive / `--force` runs are deterministic: the injected prompt echoes
  the default, so valid detected accounts are applied and invalid defaults are
  omitted rather than retried. Re-running init resumes and never rewrites the
  tracker, so an existing `bot_account` is preserved.
  """

  alias Aiur.Codeowners.Edit
  alias Aiur.Init.Format

  # GitHub login: 1–39 chars, alphanumeric with single internal hyphens, never
  # leading/trailing hyphen. Matched after `Edit.normalize_login/1` lowercases.
  #
  # The optional `[bot]` suffix is the GitHub App bot form (`<app-slug>[bot]`).
  # It remains valid here when agents publish as an App bot; the daemon App's
  # identity is configured separately under `tracker.github.github_app.account`.
  @human_login_regex ~r/^[a-z\d](?:-?[a-z\d])*$/
  @bot_login_regex ~r/^[a-z\d](?:-?[a-z\d])*(?:\[bot\])?$/
  @bot_suffix "[bot]"
  @max_login_length 39

  @operator_label "Your GitHub account"
  @bot_account_label "GitHub account Aiur's agents post as"
  @own_account "My own account"
  @separate_account "A separate bot account"

  @doc """
  Prompts for and returns the tracker with `:bot_account` filled for a GitHub
  tracker; passes any other tracker through unchanged.
  """
  @spec maybe_prompt(Aiur.Init.io(), Aiur.Init.deps(), map()) :: map()
  def maybe_prompt(io, deps, %{kind: "github"} = tracker) do
    operator = operator_account(io, deps)
    bot_default = valid_login_or_nil(Edit.normalize_login(deps.github_bot_account_default.()))

    case {operator, bot_default} do
      {operator, _bot_default} when is_binary(operator) ->
        choose_identity_mode(io, tracker, operator, bot_default)

      {nil, bot_default} when is_binary(bot_default) ->
        Map.merge(tracker, %{bot_account: bot_default, identity_mode: "separate_account"})

      {nil, nil} ->
        io.puts.(Format.dim("Skipped GitHub identity setup because no account was provided."))
        tracker
    end
  end

  def maybe_prompt(_io, _deps, tracker), do: tracker

  defp operator_account(io, deps) do
    case valid_human_login_or_nil(Edit.normalize_login(deps.github_login.())) do
      nil -> prompt_operator_account(io)
      login -> login
    end
  end

  defp prompt_operator_account(io) do
    case Edit.normalize_login(
           io.input.(
             @operator_label,
             nil,
             "This account will be trusted to direct Aiur from PR and issue comments. Leave blank to skip GitHub identity setup."
           )
         ) do
      nil ->
        nil

      login ->
        if valid_human_login?(login) do
          login
        else
          io.puts.("Enter a valid GitHub login (letters, numbers, and single hyphens).")
          prompt_operator_account(io)
        end
    end
  end

  defp choose_identity_mode(io, tracker, operator, bot_default) do
    own_option = "#{@own_account} (#{operator}) — simplest; good for solo use"
    separate_option = "#{@separate_account} — keeps agent and human activity distinguishable"
    default = if is_binary(bot_default) and bot_default != operator, do: separate_option, else: own_option

    case io.select.("Will Aiur's agents post as your own GitHub account, or as a separate bot account?", [own_option, separate_option], default) do
      ^own_option ->
        own_account_tracker(io, tracker, operator, bot_default)

      _ ->
        bot_account = prompt_bot_account(io, if(bot_default == operator, do: nil, else: bot_default), operator)
        Map.merge(tracker, %{operator_account: operator, bot_account: bot_account, identity_mode: "separate_account"})
    end
  end

  defp prompt_bot_account(io, default, operator) do
    case Edit.normalize_login(
           io.input.(
             @bot_account_label,
             default,
             "Use a different account from your own so agent and human activity stay distinguishable. Leave blank to skip the agent posting account."
           )
         ) do
      nil ->
        nil

      ^operator ->
        io.puts.("Enter a GitHub account different from your own account.")
        prompt_bot_account(io, default, operator)

      login ->
        if valid_bot_login?(login) do
          login
        else
          io.puts.("Enter a valid GitHub login (letters, numbers, and single hyphens).")
          prompt_bot_account(io, default, operator)
        end
    end
  end

  defp own_account_tracker(io, tracker, operator, bot_default) when is_binary(bot_default) and bot_default != operator do
    io.puts.("Aiur's agents are currently configured to post as @#{bot_default}, so their activity will stay separate from yours.")
    Map.merge(tracker, %{operator_account: operator, bot_account: bot_default, identity_mode: "separate_account"})
  end

  defp own_account_tracker(io, tracker, operator, _bot_default) do
    io.puts.("Aiur will mark its comments so it can tell them apart from your own.")
    Map.merge(tracker, %{operator_account: operator, bot_account: operator, identity_mode: "single_account"})
  end

  @spec valid_login_or_nil(String.t() | nil) :: String.t() | nil
  defp valid_login_or_nil(login) when is_binary(login), do: if(valid_bot_login?(login), do: login)
  defp valid_login_or_nil(_login), do: nil

  defp valid_human_login_or_nil(login) when is_binary(login), do: if(valid_human_login?(login), do: login)
  defp valid_human_login_or_nil(_login), do: nil

  # GitHub logins are ≤ 39 chars; the regex already bounds shape. Assumes a
  # login normalized by `Edit.normalize_login/1` (trimmed, lowercased, no `@`).
  # The `[bot]` suffix is GitHub's own decoration on top of the App slug, so it
  # is measured outside the 39-character login budget.
  @spec valid_bot_login?(String.t()) :: boolean()
  defp valid_bot_login?(login) do
    slug = String.replace_suffix(login, @bot_suffix, "")

    String.length(slug) <= @max_login_length and Regex.match?(@bot_login_regex, login)
  end

  defp valid_human_login?(login), do: String.length(login) <= @max_login_length and Regex.match?(@human_login_regex, login)
end
