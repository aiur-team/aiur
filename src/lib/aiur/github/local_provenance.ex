defmodule Aiur.GitHub.LocalProvenance do
  @moduledoc false
  alias Aiur.GitHub.Config
  alias Aiur.Tracker.DispatchProvenance

  @spec label_actors([map()], String.t()) :: list()
  def label_actors(events, prefix) do
    label_prefix = String.downcase(prefix) <> ":"

    events
    |> Enum.filter(fn event ->
      action = Map.get(event, "event") || Map.get(event, "type")
      label = get_in(event, ["label", "name"])
      action in ["labeled", "unlabeled"] and is_binary(label) and String.starts_with?(String.downcase(String.trim(label)), label_prefix)
    end)
    |> Enum.map(&get_in(&1, ["actor", "login"]))
    |> Enum.uniq()
  end

  @spec decision(Aiur.Issue.t(), String.t(), list(), keyword()) :: {boolean(), String.t()}
  def decision(issue, actor, appliers, opts) do
    if authorized?(issue, actor, appliers, opts), do: {true, "local_provenance"}, else: {false, "label_applier"}
  end

  @spec authorized?(Aiur.Issue.t(), String.t(), list(), keyword()) :: boolean()
  def authorized?(issue, actor, appliers, opts) do
    daemon = Keyword.get_lazy(opts, :daemon_account, &Config.daemon_account/0)
    bot = Keyword.get_lazy(opts, :bot_account, &Config.bot_account/0)
    identities = Enum.map([daemon, bot], &login/1) |> Enum.reject(&(&1 == ""))

    login(daemon) != "" and login(actor) in identities and login(issue.creator_login) == login(daemon) and
      Enum.all?(appliers, &(is_binary(&1) and login(&1) in identities)) and DispatchProvenance.authorized?(issue)
  end

  defp login(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp login(_value), do: ""
end
