defmodule Aiur.LandingWatch.TicketLookup do
  @moduledoc false

  alias Aiur.GitHub.Client
  alias Aiur.LandingWatch.LocalRead
  alias Aiur.TicketBranch

  @ticket_states ["rework", "in-progress", "todo", "human-review", "ci-wait", "merging"]

  @spec fetch(map(), keyword()) :: {:ok, String.t(), String.t(), boolean(), boolean()} | {:error, term()}
  def fetch(observation, opts) do
    case TicketBranch.ticket_id(get_in(observation.rest || %{}, ["head", "ref"])) do
      nil ->
        {:error, :pull_request_not_linked_to_ticket_branch}

      issue ->
        case LocalRead.run(Keyword.get(opts, :ticket_state_fun, &fetch_state/2), [issue, opts], opts) do
          {:ok, %{state: state, paused?: paused?, held?: held?}} -> {:ok, issue, state, paused?, held?}
          {:ok, %{state: state, paused?: paused?}} -> {:ok, issue, state, paused?, false}
          {:ok, state} -> {:ok, issue, state, false, false}
          {:error, _} = error -> error
          _ -> {:error, :ticket_state_unavailable}
        end
    end
  end

  defp fetch_state(issue, opts) do
    with {:ok, raw, _freshness} <- Client.fetch_issue_raw_conditional(issue, Keyword.put(opts, :revalidate, true)) do
      names = Enum.map(Map.get(raw, "labels", []), &Map.get(&1, "name"))
      # Gating states win while label edits add before removing the old state.
      {:ok,
       %{
         state: Enum.find(@ticket_states, "other", &("agent:#{&1}" in names)),
         paused?: "#{prefix()}:paused" in names,
         held?: "#{prefix()}:parked" in names or Enum.any?(names, &String.starts_with?(&1, "#{prefix()}:executor:"))
       }}
    end
  end

  defp prefix, do: Aiur.Config.settings!().tracker.github.label_prefix
end
