defmodule Aiur.BuildOrder.SelectedRoot do
  @moduledoc "A selected root and its bounded direct member graph candidate."

  alias Aiur.BuildOrder.{Diagnostic, Member, ProviderHealth, RootSummary}

  @max_members 1000

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

  @typedoc "An availability verdict, or `nil` when a structural verdict is meaningful."
  @type availability :: :provider_stale | :provider_unavailable | :structurally_invalid | nil

  @doc """
  The provider-availability verdict for a selected root, or `nil` when the
  provider delivered a complete generation and a structural verdict can be
  trusted.

  A graph the provider could not fetch is not a malformed graph: `members: 0` on
  a failed read is an unknown count, not a real one. Callers must resolve this
  before asking `structurally_valid?/1`, otherwise a transient outage is reported
  to the operator as a defect in their Build Order.
  """
  @spec availability(term(), term()) :: availability()
  def availability(selected, health \\ nil)

  def availability(%__MODULE__{} = selected, health) do
    health = provider_health(health || selected.provider)

    cond do
      health.state == :structurally_invalid -> :structurally_invalid
      # A concrete structural defect was observed in data we did read (a
      # duplicated identity, a malformed member, an overflowing member set).
      # That is a real claim about the graph, so it outranks provider health —
      # some producers deliberately mark the provider failed to fail closed on
      # exactly these, and that marking must not be read as an outage.
      structurally_defective?(selected) -> nil
      ProviderHealth.usable?(health) and not provider_degraded?(selected) -> nil
      health.state == :stale -> :provider_stale
      true -> :provider_unavailable
    end
  end

  def availability(_selected, _health), do: :provider_unavailable

  @spec status(term()) :: :ready | :structurally_invalid | :provider_stale | :provider_unavailable
  def status(%__MODULE__{} = selected) do
    case availability(selected, selected.provider) do
      nil -> if structurally_valid?(selected), do: :ready, else: :structurally_invalid
      availability -> availability
    end
  end

  def status(_selected), do: :structurally_invalid

  defp provider_degraded?(%__MODULE__{diagnostics: diagnostics}),
    do: Enum.any?(diagnostics, &Diagnostic.provider_sourced?/1)

  defp structurally_defective?(%__MODULE__{diagnostics: diagnostics}),
    do: Enum.any?(diagnostics, &(not Diagnostic.provider_sourced?(&1)))

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
