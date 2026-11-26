defmodule Aiur.AllowedContributors.AllowList do
  @moduledoc """
  Validation for the config allow-list and parser for its file fallback.

  The file names identities by **numeric GitHub id only**:

      # comment
      user 583231            # octocat — the login is a comment, never matched
      org 9919 github        # an org needs its login to address the REST API

  A login is never an identity here: it can be renamed, and a deleted
  account's login can be re-registered by anyone. A user line therefore
  carries an id and nothing that is matched. An org line carries the login
  only to build `GET /orgs/{login}/memberships/{user}`; the response's
  `organization.id` must still equal the id on the line, so a renamed org
  whose old name was re-registered fails closed (see
  `Aiur.AllowedContributors.Membership`).

  The grammar is deliberately closed. There is no `team`, `@org/team`,
  `include`, or wildcard form, so an allowed contributor cannot be a route to
  trusting anyone else (no transitive trust). Any line that does not parse
  invalidates the **whole** file: a half-read allow-list is not a smaller
  allow-list, it is an unknown one, and unknown fails closed.
  """

  alias Aiur.Config.Schema.AllowedContributorsParser

  @type t :: %{users: %{optional(pos_integer()) => true}, orgs: %{optional(pos_integer()) => String.t()}}
  @type error :: {:line, pos_integer(), atom()} | :too_large | :not_utf8

  @doc "Whether `login` is a plain ASCII GitHub login, safe to place in an API path."
  @spec valid_login?(term()) :: boolean()
  defdelegate valid_login?(login), to: AllowedContributorsParser

  @doc "An allow-list that admits nobody."
  @spec empty() :: t()
  defdelegate empty(), to: AllowedContributorsParser

  @doc "Parses the file body. Any malformed line fails the whole file."
  @spec parse(binary()) :: {:ok, t()} | {:error, error()}
  defdelegate parse(body), to: AllowedContributorsParser

  @doc "Validates numeric user ids and org maps with numeric id and API login."
  @spec from_config(term()) :: {:ok, t()} | {:error, String.t()}
  defdelegate from_config(config), to: AllowedContributorsParser

  @doc """
  Entries added and removed between two allow-lists, as display strings
  (`user:<id>`, `org:<id>:<login>`), for the change alert.
  """
  @spec diff(t(), t()) :: %{added: [String.t()], removed: [String.t()]}
  def diff(old, new) do
    old_entries = entries(old)
    new_entries = entries(new)

    %{
      added: new_entries |> MapSet.difference(old_entries) |> Enum.sort(),
      removed: old_entries |> MapSet.difference(new_entries) |> Enum.sort()
    }
  end

  defp entries(%{users: users, orgs: orgs}) do
    user_entries = Enum.map(users, fn {id, true} -> "user:#{id}" end)
    org_entries = Enum.map(orgs, fn {id, login} -> "org:#{id}:#{login}" end)
    MapSet.new(user_entries ++ org_entries)
  end
end
