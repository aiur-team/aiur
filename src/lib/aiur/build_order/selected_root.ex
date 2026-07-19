defmodule Aiur.BuildOrder.SelectedRoot do
  @moduledoc "A selected root and its bounded direct member graph candidate."

  alias Aiur.BuildOrder.{Diagnostic, Member, ProviderHealth, RootSummary}

  @max_members 100

  @type t :: %__MODULE__{
          root: RootSummary.t(),
          members: [Member.t()],
          provider: ProviderHealth.t(),
          diagnostics: [Diagnostic.t()],
          planning?: boolean()
        }

  defstruct [:root, members: [], provider: %ProviderHealth{}, diagnostics: [], planning?: false]

  @spec new(term(), term(), term(), keyword()) :: t()
  def new(root, members, provider, opts \\ [])

  def new(root, members, provider, opts) when is_list(members) do
    overflow? = length(members) > @max_members
    {members, malformed?} = members |> Enum.take(@max_members) |> members()

    diagnostics =
      overflow_diagnostic(overflow?) ++ malformed_diagnostic(malformed?)

    %__MODULE__{
      root: root_summary(root),
      members: members,
      provider: provider_health(provider),
      diagnostics: diagnostics,
      planning?: Keyword.get(opts, :planning?, false)
    }
  end

  def new(root, _members, provider, opts),
    do: %__MODULE__{
      root: root_summary(root),
      provider: provider_health(provider),
      diagnostics: [Diagnostic.new(:invalid_member)],
      planning?: Keyword.get(opts, :planning?, false)
    }

  @spec structurally_valid?(term()) :: boolean()
  def structurally_valid?(%__MODULE__{root: root, diagnostics: []}), do: RootSummary.valid?(root)
  def structurally_valid?(_selected), do: false

  @spec status(term()) :: :ready | :structurally_invalid | :provider_stale | :provider_unavailable
  def status(%__MODULE__{} = selected) do
    cond do
      not structurally_valid?(selected) -> :structurally_invalid
      ProviderHealth.usable?(selected.provider) -> :ready
      match?(%ProviderHealth{state: :stale}, selected.provider) -> :provider_stale
      true -> :provider_unavailable
    end
  end

  def status(_selected), do: :structurally_invalid

  defp root_summary(%RootSummary{} = root), do: root
  defp root_summary(_root), do: RootSummary.new(%{})
  defp provider_health(%ProviderHealth{} = provider), do: provider
  defp provider_health(_provider), do: %ProviderHealth{}

  defp members(members) do
    {records, malformed} = Enum.split_with(members, &match?(%Member{}, &1))
    {records, malformed != [] or Enum.any?(records, &(not Member.structurally_valid?(&1)))}
  end

  defp overflow_diagnostic(true), do: [Diagnostic.new(:member_overflow)]
  defp overflow_diagnostic(false), do: []
  defp malformed_diagnostic(true), do: [Diagnostic.new(:invalid_member)]
  defp malformed_diagnostic(false), do: []
end
