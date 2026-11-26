defmodule Aiur.Ownership.WaitingLabel do
  @moduledoc """
  The delegating gateway's per-poll pass over `gateway-waiting:project-missing`.

  Best effort and additive: a failed write is logged and retried on the next poll. The label is a
  projection of the ownership ref; dispatch never reads it.
  """

  require Logger

  alias Aiur.GitHub.Labels
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Ownership.{Delegation, PeerState}

  @spec run(Aiur.Issue.t(), String.t(), String.t(), term(), String.t(), keyword()) :: :ok
  def run(issue, repo, ticket, ref, self_id, opts \\ []) do
    label = Labels.gateway_waiting_label()
    labelled? = label in issue.labels
    delegation = PeerState.delegation(repo, ticket)
    owner_list = with {:owned, r} <- ref, do: list(Keyword.get(opts, :peer_fun, &PeerState.peer/1), r)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case Delegation.waiting_action(labelled?, ref, repo, delegation, owner_list, self_id, now) do
      :add -> apply_label(:add, issue, label, opts)
      :remove -> apply_label(:remove, issue, label, opts) |> drop(repo, ticket)
      :keep -> :ok
    end
  rescue
    error -> Logger.warning("waiting label pass failed for ##{issue.identifier}: #{Exception.message(error)}")
  end

  defp list(peer_fun, record) do
    case peer_fun.(record.gateway_id) do
      %{projects: projects, observed_at: %DateTime{} = at} when is_list(projects) -> %{projects: projects, observed_at: at}
      _ -> nil
    end
  end

  defp apply_label(:add, issue, label, opts) do
    ensure = Keyword.get(opts, :ensure_fun, &Labels.ensure_waiting_label/0)
    write = Keyword.get(opts, :write_fun, &TicketTransition.write_marker(&1, &2, &3, writer: :ownership))

    with :ok <- ensure.(), :ok <- write.(to_string(issue.identifier), :add, label) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("#{label} not added to ##{issue.identifier}: #{inspect(reason)}")
        error
    end
  end

  defp apply_label(:remove, issue, label, opts) do
    write = Keyword.get(opts, :write_fun, &TicketTransition.write_marker(&1, &2, &3, writer: :ownership))
    write.(to_string(issue.identifier), :remove, label)
  end

  defp drop(:ok, repo, ticket) do
    _ = PeerState.drop_delegation(repo, ticket)
    :ok
  end

  defp drop(_error, _repo, _ticket), do: :ok
end
