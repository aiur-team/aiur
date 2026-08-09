defmodule Aiur.BuildOrder.RootSummary do
  @moduledoc "A visible root-catalog entry with per-entry structural validity."

  alias Aiur.{BuildOrder.Bounded, BuildOrder.Diagnostic, BuildOrder.Lifecycle, TrackerIdentity}

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t() | nil,
          title: String.t(),
          icon: String.t() | nil,
          url: String.t() | nil,
          parent_identity: TrackerIdentity.t() | nil,
          lifecycle: Lifecycle.t(),
          labels: [String.t()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          member_count: non_neg_integer() | nil,
          epic_count: non_neg_integer() | nil,
          phase_count: non_neg_integer() | nil,
          progress: non_neg_integer() | nil,
          progress_resolution: :resolved | :partial | :unresolved | :unknown,
          progress_resolved_count: non_neg_integer() | nil,
          completed?: boolean(),
          diagnostics: [Diagnostic.t()]
        }

  defstruct identity: nil,
            title: "Untitled Build Order",
            icon: nil,
            url: nil,
            parent_identity: nil,
            lifecycle: %Lifecycle{},
            labels: [],
            created_at: nil,
            updated_at: nil,
            member_count: nil,
            epic_count: nil,
            phase_count: nil,
            progress: nil,
            progress_resolution: :unknown,
            progress_resolved_count: nil,
            completed?: false,
            diagnostics: []

  @spec new(term()) :: t()
  def new(attributes) when is_map(attributes) do
    identity = identity(Map.get(attributes, :identity))
    {title, title_diagnostic} = title(Map.get(attributes, :title))
    {url, url_diagnostic} = url(Map.get(attributes, :url), identity)
    {parent, parent_diagnostic} = parent(Map.get(attributes, :parent_identity))

    {progress, progress_resolution} =
      progress(percent(Map.get(attributes, :progress)), Map.get(attributes, :progress_resolution))

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
      icon: icon(Map.get(attributes, :icon)),
      url: url,
      parent_identity: parent,
      lifecycle: lifecycle(attributes),
      labels: labels(Map.get(attributes, :labels, [])),
      created_at: datetime(Map.get(attributes, :created_at)),
      updated_at: datetime(Map.get(attributes, :updated_at)),
      member_count: count(Map.get(attributes, :member_count)),
      epic_count: count(Map.get(attributes, :epic_count)),
      phase_count: count(Map.get(attributes, :phase_count)),
      progress: progress,
      progress_resolution: progress_resolution,
      progress_resolved_count: count(Map.get(attributes, :progress_resolved_count)),
      completed?: Map.get(attributes, :completed?) == true,
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

  defp icon(value) when is_binary(value) and byte_size(value) in 1..80, do: value
  defp icon(_value), do: nil

  defp url(value, nil), do: safe_url(value)

  defp url(value, identity) do
    case Bounded.github_issue_url_for(value, identity) do
      {:ok, url} -> {url, nil}
      :error -> {nil, Diagnostic.new(:invalid_url)}
    end
  end

  defp safe_url(value) do
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

  defp lifecycle(%{lifecycle: %Lifecycle{} = lifecycle}), do: lifecycle

  defp lifecycle(attributes),
    do: Lifecycle.from_github(Map.get(attributes, :state), Map.get(attributes, :state_reason))

  defp labels(labels) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp labels(_labels), do: []

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  defp percent(value) when is_integer(value) and value in 0..100, do: value
  defp percent(_value), do: nil

  # A source that resolved completion for at least some members says so
  # explicitly. `:unknown` is the legacy shape — a percent with no claim about
  # how it was derived — and is preserved so callers that never resolved
  # completion at all keep rendering exactly as before. A declared
  # `:resolved`/`:partial` with no usable percent fails closed to
  # `:unresolved` rather than degrading into an indistinguishable blank.
  defp progress(nil, resolution) when resolution in [:resolved, :partial, :unresolved], do: {nil, :unresolved}
  defp progress(_percent, :unresolved), do: {nil, :unresolved}
  defp progress(percent, resolution) when resolution in [:resolved, :partial], do: {percent, resolution}
  defp progress(percent, _resolution), do: {percent, :unknown}
  defp datetime(%DateTime{} = datetime), do: datetime
  defp datetime(_datetime), do: nil
end
