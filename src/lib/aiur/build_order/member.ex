defmodule Aiur.BuildOrder.Member do
  @moduledoc "A member record that retains metadata warnings without dropping the member."

  alias Aiur.BuildOrder.{Activity, Bounded, Dependency, Diagnostic, Lifecycle, Metadata}
  alias Aiur.TrackerIdentity

  @type t :: %__MODULE__{
          identity: TrackerIdentity.t() | nil,
          title: String.t(),
          url: String.t() | nil,
          metadata: Metadata.t(),
          lifecycle: Lifecycle.t(),
          activity: Activity.t(),
          parent_identity: TrackerIdentity.t() | nil,
          labels: [String.t()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          connection_counts: %{blocked_by: non_neg_integer(), blocking: non_neg_integer()},
          dependencies: [Dependency.t()],
          document_url: String.t() | nil,
          document_path: String.t() | nil,
          draft_body: String.t() | nil,
          icon: String.t() | nil,
          draft?: boolean(),
          diagnostics: [Diagnostic.t()]
        }

  defstruct identity: nil,
            title: "Untitled ticket",
            url: nil,
            document_url: nil,
            document_path: nil,
            draft_body: nil,
            icon: nil,
            draft?: false,
            metadata: %Metadata{},
            lifecycle: %Lifecycle{},
            activity: %Activity{},
            parent_identity: nil,
            labels: [],
            created_at: nil,
            updated_at: nil,
            connection_counts: %{blocked_by: 0, blocking: 0},
            dependencies: [],
            diagnostics: []

  @spec new(term()) :: t()
  def new(attributes) when is_map(attributes) do
    identity = identity(Map.get(attributes, :identity))
    {title, title_diagnostic} = title(Map.get(attributes, :title))
    {url, url_diagnostic} = url(Map.get(attributes, :url), identity)
    metadata = Metadata.parse(Map.get(attributes, :labels, []))
    marker_diagnostics = marker_diagnostics(Map.get(attributes, :marker))
    {dependencies, dependency_diagnostics} = dependencies(attributes)

    diagnostics =
      Enum.reject(
        [identity_diagnostic(identity), title_diagnostic, url_diagnostic] ++
          marker_diagnostics ++ dependency_diagnostics,
        &is_nil/1
      )

    %__MODULE__{
      identity: identity,
      title: title,
      url: url,
      metadata: metadata,
      lifecycle: lifecycle(attributes),
      activity: activity(attributes),
      parent_identity: parent_identity(Map.get(attributes, :parent_identity)),
      labels: labels(Map.get(attributes, :labels, [])),
      created_at: datetime(Map.get(attributes, :created_at)),
      updated_at: datetime(Map.get(attributes, :updated_at)),
      connection_counts: connection_counts(Map.get(attributes, :connection_counts)),
      dependencies: dependencies,
      document_url: document_url(Map.get(attributes, :document_url)),
      document_path: document_path(Map.get(attributes, :document_path)),
      draft_body: draft_body(Map.get(attributes, :draft_body)),
      icon: icon(Map.get(attributes, :icon)),
      draft?: Map.get(attributes, :draft?) == true,
      diagnostics: diagnostics
    }
  end

  def new(_attributes), do: new(%{})

  defp document_url(value) when is_binary(value) and byte_size(value) in 1..512, do: value
  defp document_url(_value), do: nil

  defp document_path(value) when is_binary(value) and byte_size(value) in 1..512, do: value
  defp document_path(_value), do: nil

  defp draft_body(value) when is_binary(value) and byte_size(value) in 1..64_000, do: value
  defp draft_body(_value), do: nil

  defp icon(value) when is_binary(value) and byte_size(value) in 1..80, do: value
  defp icon(_value), do: nil

  @spec structurally_valid?(term()) :: boolean()
  def structurally_valid?(%__MODULE__{identity: identity, diagnostics: diagnostics})
      when is_list(diagnostics) do
    TrackerIdentity.joinable?(identity) and
      Enum.all?(diagnostics, fn
        %Diagnostic{code: code} ->
          code not in [
            :connection_overflow,
            :duplicate_identity,
            :invalid_identity,
            :invalid_dependency,
            :invalid_endpoint_locator,
            :invalid_member,
            :invalid_label_connection,
            :invalid_lifecycle,
            :invalid_title,
            :invalid_url,
            :incomplete_labels,
            :labels_overflow,
            :unresolved_internal_dependency
          ]

        _other ->
          false
      end)
  end

  def structurally_valid?(_member), do: false

  defp title(value) do
    case Bounded.title(value) do
      {:ok, title} -> {title, nil}
      :error -> {"Untitled ticket", Diagnostic.new(:invalid_title)}
    end
  end

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

  defp lifecycle(%{lifecycle: %Lifecycle{} = lifecycle}), do: lifecycle

  defp lifecycle(attributes),
    do: Lifecycle.from_github(Map.get(attributes, :state), Map.get(attributes, :state_reason))

  defp activity(%{activity: %Activity{} = activity}), do: activity

  defp activity(attributes),
    do:
      Activity.new(
        Map.get(attributes, :execution_state),
        Map.get(attributes, :agent_stage),
        Map.get(attributes, :progress)
      )

  defp dependencies(attributes) do
    {dependencies, malformed} =
      attributes
      |> Map.get(:dependencies, [])
      |> List.wrap()
      |> Enum.split_with(&match?(%Dependency{}, &1))

    {dependencies, if(malformed == [], do: [], else: [Diagnostic.new(:invalid_dependency)])}
  end

  defp marker_diagnostics({:warning, diagnostic}), do: [diagnostic]
  defp marker_diagnostics(_marker), do: []

  defp parent_identity(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity), do: identity, else: nil
  end

  defp parent_identity(_identity), do: nil

  defp labels(labels) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp labels(_labels), do: []
  defp datetime(%DateTime{} = datetime), do: datetime
  defp datetime(_datetime), do: nil

  defp connection_counts(%{blocked_by: blocked_by, blocking: blocking})
       when is_integer(blocked_by) and blocked_by >= 0 and is_integer(blocking) and blocking >= 0,
       do: %{blocked_by: blocked_by, blocking: blocking}

  defp connection_counts(_counts), do: %{blocked_by: 0, blocking: 0}
end
