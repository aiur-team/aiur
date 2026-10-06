defmodule Aiur.AllowedContributors.Policy do
  @moduledoc """
  Pure eligibility rules for an allowed-contributor candidate, applied before
  the allow-list is consulted.

  These rules only ever *narrow*: each one is a reason to reject, never a
  reason to admit. Admission is decided solely by the numeric author id
  (`user_listed?/2`) or verified org membership.
  """

  alias Aiur.AllowedContributors.Candidate

  @doc """
  Screens a candidate's shape. `aiur_logins` are Aiur's own bot and daemon
  logins (lowercased): an agent-filed issue is not outside intake, even when
  the agent account is a member of an allowed org.
  """
  @spec screen(Candidate.t(), [String.t()]) :: :ok | {:reject, atom()}
  def screen(candidate, aiur_logins) do
    cond do
      not positive?(candidate.number) -> {:reject, :malformed_candidate}
      not positive?(candidate.author_id) -> {:reject, :missing_author_id}
      # "Bot" (GitHub Apps' bot users), "Organization", "Mannequin" — only a
      # real user account can be an allowed contributor.
      candidate.author_type != "User" -> {:reject, :not_a_user}
      candidate.via_app? -> {:reject, :created_via_app}
      aiur_login?(candidate.author_login, aiur_logins) -> {:reject, :aiur_account}
      true -> :ok
    end
  end

  @doc "Whether the author's numeric id is listed as an individual."
  @spec user_listed?(%{users: map()}, pos_integer()) :: boolean()
  def user_listed?(%{users: users}, author_id), do: Map.has_key?(users, author_id)

  defp positive?(value), do: is_integer(value) and value > 0

  defp aiur_login?(login, aiur_logins) when is_binary(login),
    do: String.downcase(String.trim(login)) in aiur_logins

  defp aiur_login?(_login, _aiur_logins), do: false
end
