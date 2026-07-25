defmodule Aiur.CurrentRunOutcomeSnapshot.MembershipIndex do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @type t :: %{by_locator: map(), signature: String.t()}

  @spec build([map() | TrackerIdentity.t()]) :: t()
  def build(members) when is_list(members) do
    by_locator =
      Enum.reduce(members, %{}, fn member, index ->
        case member_identity(member) do
          %TrackerIdentity{} = identity -> put_identity(index, identity)
          _identity -> index
        end
      end)

    %{by_locator: by_locator, signature: signature(members)}
  end

  def build(_members), do: build([])

  @spec lookup(t(), String.t(), {String.t(), String.t()}) ::
          {:ok, TrackerIdentity.t()} | {:error, :not_current_member | :ambiguous_identity}
  def lookup(%{by_locator: index}, locator, {owner, repository}) do
    case Map.get(index, locator_key(owner, repository, locator)) do
      {:unique, identity} -> {:ok, identity}
      :ambiguous -> {:error, :ambiguous_identity}
      nil -> {:error, :not_current_member}
    end
  end

  @spec signature([map() | TrackerIdentity.t()]) :: String.t()
  def signature(members) when is_list(members) do
    members
    |> Enum.map(&member_identity/1)
    |> Enum.map(&identity_signature/1)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def signature(_members), do: signature([])

  defp put_identity(index, %TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity) do
      key = locator_key(identity.owner, identity.repository, identity.identifier)

      Map.update(index, key, {:unique, identity}, fn
        {:unique, existing} when existing == identity -> {:unique, existing}
        _existing -> :ambiguous
      end)
    else
      index
    end
  end

  defp locator_key(owner, repository, identifier) do
    {String.downcase(owner), String.downcase(repository), identifier}
  end

  defp member_identity(%TrackerIdentity{} = identity), do: identity
  defp member_identity(%{identity: identity}), do: identity
  defp member_identity(%{tracker_identity: identity}), do: identity
  defp member_identity(_member), do: nil

  defp identity_signature(%TrackerIdentity{} = identity) do
    TrackerIdentity.github_key(identity) ||
      {:unjoinable, identity.kind, identity.owner, identity.repository, identity.identifier, identity.reason}
  end

  defp identity_signature(_identity), do: {:unjoinable, nil}
end
