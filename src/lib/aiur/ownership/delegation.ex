defmodule Aiur.Ownership.Delegation do
  @moduledoc """
  Pure decisions for delegating a ticket to another gateway (no I/O).

  A peer's project list is `nil` (never seen) or `%{projects: [repo], observed_at: DateTime}`.
  Unknown never refuses and never labels: only a fresh list that lacks the repo counts as evidence.
  """

  @fresh_ms 600_000

  @spec fresh_ms() :: pos_integer()
  def fresh_ms, do: @fresh_ms

  @spec check_target(map() | nil, String.t(), String.t(), DateTime.t()) :: :ok | {:warn, String.t()} | {:refuse, String.t()}
  def check_target(nil, _repo, to, _now), do: {:warn, "#{to} unreachable; project list unknown; transfer written"}

  def check_target(%{projects: projects} = list, repo, to, now) do
    cond do
      runs?(projects, repo) -> :ok
      fresh?(list, now) -> {:refuse, "#{to} does not run #{repo}"}
      true -> {:warn, "#{to} did not answer; its last list (#{div(age(list, now), 60_000)} min old) lacked #{repo}; transfer written"}
    end
  end

  @doc """
  What the delegating gateway does to the waiting label on a poll.

  `ref` is `{:owned, record}` or `:unowned`; `delegation` is our stored `%{epoch: n}` for the ticket or `nil`.
  """
  @spec waiting_action(boolean(), term(), String.t(), map() | nil, map() | nil, String.t(), DateTime.t()) :: :add | :remove | :keep
  def waiting_action(labelled?, ref, repo, delegation, owner_list, self_id, now),
    do: decide(labelled?, ref, delegation, self_id, listed(owner_list, repo, now))

  defp listed(list, repo, now) do
    cond do
      list == nil or not fresh?(list, now) -> :unknown
      runs?(list.projects, repo) -> :has
      true -> :missing
    end
  end

  defp decide(_labelled?, {:unreadable, _}, _delegation, _self_id, _listed), do: :keep
  defp decide(false, {:owned, r}, delegation, self_id, listed), do: if(add?(r, delegation, self_id, listed == :missing), do: :add, else: :keep)
  defp decide(true, {:owned, r}, delegation, self_id, listed), do: if(clear?(r, delegation, self_id, listed == :has), do: :remove, else: :keep)
  defp decide(true, :unowned, _delegation, _self_id, _listed), do: :remove
  defp decide(false, :unowned, _delegation, _self_id, _listed), do: :keep

  defp add?(r, delegation, self_id, missing?),
    do: missing? and r.gateway_id != self_id and r.reason == "transfer" and delegation != nil and delegation.epoch == r.epoch

  defp clear?(r, delegation, self_id, has?),
    do: r.gateway_id == self_id or has? or (delegation != nil and r.epoch > delegation.epoch)

  # GitHub repo names are case-insensitive; peers report theirs downcased.
  defp runs?(projects, repo), do: String.downcase(repo) in Enum.map(projects, &String.downcase/1)

  defp fresh?(%{observed_at: at}, now), do: age(%{observed_at: at}, now) <= @fresh_ms
  defp age(%{observed_at: at}, now), do: max(DateTime.diff(now, at, :millisecond), 0)
end
