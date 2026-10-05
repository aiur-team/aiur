defmodule Aiur.AllowedContributors.AllowList do
  @moduledoc """
  Parser for the `.github/ALLOWED-CONTRIBUTORS` allow-list.

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

  @max_bytes 65_536
  # GitHub ids are positive int64s. ASCII digits only — `String.to_integer/1`
  # would happily accept a sign, and a lookalike digit must never parse.
  @id ~r/\A[1-9][0-9]{0,18}\z/
  # GitHub org/user login charset: ASCII alphanumerics and single interior
  # hyphens, at most 39 characters. Anything else (unicode lookalikes
  # included) is rejected rather than normalized.
  @login ~r/\A[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}\z/

  @type t :: %{users: MapSet.t(pos_integer()), orgs: %{pos_integer() => String.t()}}
  @type error :: {:line, pos_integer(), atom()} | :too_large | :not_utf8

  @doc "An allow-list that admits nobody."
  @spec empty() :: t()
  def empty, do: %{users: MapSet.new(), orgs: %{}}

  @doc "Parses the file body. Any malformed line fails the whole file."
  @spec parse(binary()) :: {:ok, t()} | {:error, error()}
  def parse(body) when is_binary(body) and byte_size(body) > @max_bytes, do: {:error, :too_large}

  def parse(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> String.split(["\r\n", "\n"])
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, empty()}, &parse_line/2)
    else
      {:error, :not_utf8}
    end
  end

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
    user_entries = Enum.map(users, &"user:#{&1}")
    org_entries = Enum.map(orgs, fn {id, login} -> "org:#{id}:#{login}" end)
    MapSet.new(user_entries ++ org_entries)
  end

  defp parse_line({line, number}, {:ok, acc}) do
    case line |> strip_comment() |> String.split([" ", "\t"], trim: true) do
      [] -> {:cont, {:ok, acc}}
      ["user", id] -> add_user(acc, id, number)
      ["org", id, login] -> add_org(acc, id, login, number)
      _other -> {:halt, {:error, {:line, number, :unrecognized_entry}}}
    end
  end

  defp strip_comment(line) do
    case String.split(line, "#", parts: 2) do
      [content | _comment] -> content
      [] -> ""
    end
  end

  defp add_user(acc, id, number) do
    case parse_id(id) do
      {:ok, int} -> {:cont, {:ok, %{acc | users: MapSet.put(acc.users, int)}}}
      :error -> {:halt, {:error, {:line, number, :invalid_id}}}
    end
  end

  defp add_org(acc, id, login, number) do
    with {:ok, int} <- parse_id(id),
         true <- Regex.match?(@login, login) do
      put_org(acc, int, login, number)
    else
      :error -> {:halt, {:error, {:line, number, :invalid_id}}}
      false -> {:halt, {:error, {:line, number, :invalid_login}}}
    end
  end

  defp put_org(acc, id, login, number) do
    case Map.fetch(acc.orgs, id) do
      {:ok, existing} when existing != login -> {:halt, {:error, {:line, number, :conflicting_org}}}
      _same_or_new -> {:cont, {:ok, %{acc | orgs: Map.put(acc.orgs, id, login)}}}
    end
  end

  defp parse_id(text) do
    if Regex.match?(@id, text) do
      case Integer.parse(text) do
        {int, ""} when int > 0 and int <= 9_223_372_036_854_775_807 -> {:ok, int}
        _other -> :error
      end
    else
      :error
    end
  end
end
