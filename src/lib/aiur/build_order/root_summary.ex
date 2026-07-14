defmodule Aiur.BuildOrder.RootSummary do
  @moduledoc "A visible root-catalog entry with per-entry structural validity."

  alias Aiur.{BuildOrder.Bounded, BuildOrder.Diagnostic, TrackerIdentity}

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t() | nil,
          title: String.t(),
          url: String.t() | nil,
          parent_identity: TrackerIdentity.t() | nil,
          diagnostics: [Diagnostic.t()]
        }

  defstruct identity: nil,
            title: "Untitled Build Order",
            url: nil,
            parent_identity: nil,
            diagnostics: []

  @spec new(term()) :: t()
  def new(attributes) when is_map(attributes) do
    {title, title_diagnostic} = title(Map.get(attributes, :title))
    {url, url_diagnostic} = url(Map.get(attributes, :url))
    identity = identity(Map.get(attributes, :identity))
    {parent, parent_diagnostic} = parent(Map.get(attributes, :parent_identity))

    diagnostics =
      Enum.reject(
        [
          identity_diagnostic(identity),
          title_diagnostic,
          url_diagnostic,
          parent_diagnostic
        ],
        &is_nil/1
      )

    %__MODULE__{
      identity: identity,
      title: title,
      url: url,
      parent_identity: parent,
      diagnostics: diagnostics
    }
  end

  def new(_attributes), do: new(%{})

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{diagnostics: []}), do: true
  def valid?(_root), do: false

  defp title(value) do
    case Bounded.title(value) do
      {:ok, title} -> {title, nil}
      :error -> {"Untitled Build Order", Diagnostic.new(:invalid_title)}
    end
  end

  defp url(value) do
    case Bounded.github_url(value) do
      {:ok, url} -> {url, nil}
      :error -> {nil, Diagnostic.new(:invalid_url)}
    end
  end

  defp identity(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity), do: identity, else: nil
  end

  defp identity(_identity), do: nil

  defp identity_diagnostic(nil), do: Diagnostic.new(:invalid_identity)
  defp identity_diagnostic(_identity), do: nil

  defp parent(nil), do: {nil, nil}

  defp parent(%TrackerIdentity{} = parent) do
    if TrackerIdentity.joinable?(parent), do: {parent, Diagnostic.new(:root_has_parent)}, else: {nil, Diagnostic.new(:root_has_parent)}
  end

  defp parent(_parent), do: {nil, Diagnostic.new(:root_has_parent)}
end
