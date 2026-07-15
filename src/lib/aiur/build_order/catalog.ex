defmodule Aiur.BuildOrder.Catalog do
  @moduledoc "A bounded root catalog that never lets one invalid entry hide its siblings."

  alias Aiur.{BuildOrder.Diagnostic, BuildOrder.ProviderHealth, BuildOrder.RootSummary, TrackerIdentity}

  @max_entries 100

  @type selection ::
          {:ok, RootSummary.t()}
          | {:structurally_invalid, RootSummary.t()}
          | {:provider_stale, RootSummary.t()}
          | {:provider_unavailable, RootSummary.t()}
          | :not_found
  @type t :: %__MODULE__{
          entries: [RootSummary.t()],
          provider: ProviderHealth.t(),
          diagnostics: [Diagnostic.t()]
        }

  defstruct entries: [], provider: %ProviderHealth{}, diagnostics: []

  @spec new(term(), term()) :: t()
  def new(entries, provider) when is_list(entries) do
    overflow? = length(entries) > @max_entries
    entries = Enum.take(entries, @max_entries)

    diagnostics =
      overflow_diagnostic(overflow?) ++ invalid_root_diagnostic(entries)

    %__MODULE__{
      entries: Enum.map(entries, &root_summary/1),
      provider: provider_health(provider),
      diagnostics: diagnostics
    }
  end

  def new(_entries, provider),
    do: %__MODULE__{
      provider: provider_health(provider),
      diagnostics: [Diagnostic.new(:catalog_overflow)]
    }

  @spec select(t(), term()) :: selection()
  def select(%__MODULE__{} = catalog, identity) do
    case Enum.find(catalog.entries, &same_identity?(&1.identity, identity)) do
      nil -> :not_found
      root -> selection(root, catalog.provider)
    end
  end

  defp selection(root, provider) do
    if RootSummary.valid?(root),
      do: provider_selection(root, provider),
      else: {:structurally_invalid, root}
  end

  defp provider_selection(root, provider) do
    if ProviderHealth.usable?(provider), do: {:ok, root}, else: unavailable_selection(root, provider)
  end

  defp unavailable_selection(root, %ProviderHealth{state: :stale}), do: {:provider_stale, root}
  defp unavailable_selection(root, _provider), do: {:provider_unavailable, root}
  defp provider_health(%ProviderHealth{} = provider), do: provider
  defp provider_health(_provider), do: %ProviderHealth{}
  defp root_summary(%RootSummary{} = root), do: root
  defp root_summary(_root), do: RootSummary.new(%{})

  defp overflow_diagnostic(true), do: [Diagnostic.new(:catalog_overflow)]
  defp overflow_diagnostic(false), do: []

  defp invalid_root_diagnostic(entries) do
    if Enum.all?(entries, &match?(%RootSummary{}, &1)), do: [], else: [Diagnostic.new(:invalid_root)]
  end

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    case {TrackerIdentity.github_key(left), TrackerIdentity.github_key(right)} do
      {{:github, _, _, _} = left_key, {:github, _, _, _} = right_key} -> left_key == right_key
      _ -> false
    end
  end

  defp same_identity?(_left, _right), do: false
end
