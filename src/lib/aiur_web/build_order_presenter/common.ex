defmodule AiurWeb.BuildOrderPresenter.Common do
  @moduledoc "Identity keys and diagnostic normalization shared by the Build Order presenter modules."

  alias Aiur.BuildOrder.{Diagnostic, Member}
  alias Aiur.TrackerIdentity

  @doc false
  @spec normalize_diagnostics([term()]) :: [Diagnostic.t()]
  def normalize_diagnostics(diagnostics) do
    diagnostics
    |> Enum.filter(&match?(%Diagnostic{}, &1))
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end

  @doc false
  @spec identity_key(term()) :: term()
  def identity_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  def identity_key(_identity), do: nil

  @doc false
  @spec member_sort_key(Member.t()) :: term()
  def member_sort_key(%Member{} = member), do: member_key(member)

  @doc false
  @spec member_key(Member.t()) :: term()
  def member_key(%Member{identity: identity, title: title, url: url}),
    do: identity_key(identity) || {:invalid_member, title, url}
end
