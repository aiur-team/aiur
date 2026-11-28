defmodule Aiur.GitHub.DispatchAuthorization.Decision do
  @moduledoc false

  alias Aiur.GitHub.{Config, LocalProvenance, MainFixer}

  @spec decide(Aiur.Issue.t(), String.t(), String.t() | nil, String.t() | nil, list(), MapSet.t(), keyword()) :: {boolean(), String.t()}
  def decide(issue, actor, triaged_by, daemon_triage, label_actors, allowed_users, opts) do
    cond do
      main_fixer_actor?(issue, actor, opts) -> {true, "main_watch_fixer"}
      daemon_queue_authorized?(actor, daemon_triage, opts) -> {true, "daemon_label_applier"}
      trusted_label_applier?(actor, allowed_users, opts) -> {true, "label_applier"}
      prior_aiur_triage?(actor, daemon_triage, triaged_by, opts) -> {true, prior_triage_source(daemon_triage, triaged_by)}
      true -> LocalProvenance.decision(issue, actor, label_actors, opts)
    end
  end

  defp daemon_queue_authorized?(actor, daemon_triage, opts),
    do: not is_nil(daemon_triage) and daemon_actor?(actor, opts)

  defp trusted_label_applier?(actor, allowed_users, opts),
    do: not daemon_actor?(actor, opts) and member?(allowed_users, actor)

  defp prior_aiur_triage?(actor, daemon_triage, triaged_by, opts),
    do: aiur_actor?(actor, opts) and (not is_nil(daemon_triage) or not is_nil(triaged_by))

  defp prior_triage_source(daemon_triage, _triaged_by) when is_binary(daemon_triage),
    do: "prior_daemon_triage:#{daemon_triage}"

  defp prior_triage_source(_daemon_triage, triaged_by), do: "prior_triage:#{triaged_by}"

  defp main_fixer_actor?(issue, actor, opts), do: MainFixer.authorized?(issue, opts) and aiur_actor?(actor, opts)

  defp aiur_actor?(actor, opts) do
    trimmed = actor |> String.trim() |> String.downcase()
    trimmed != "" and trimmed in aiur_logins(opts)
  end

  defp daemon_actor?(actor, opts) do
    daemon = Keyword.get_lazy(opts, :daemon_account, &Config.daemon_account/0)
    normalized_login(actor) != "" and normalized_login(actor) == normalized_login(daemon)
  end

  defp normalized_login(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized_login(_value), do: ""

  defp aiur_logins(opts) do
    [
      Keyword.get_lazy(opts, :bot_account, &Config.bot_account/0),
      Keyword.get_lazy(opts, :daemon_account, &Config.daemon_account/0)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp member?(allowed_users, login),
    do: MapSet.member?(allowed_users, String.downcase(String.trim(login)))
end
