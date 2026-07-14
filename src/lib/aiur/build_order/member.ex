defmodule Aiur.BuildOrder.Activity do
  @moduledoc "Aiur execution evidence kept separate from GitHub lifecycle facts."

  @type progress :: 0..100 | :unknown
  @type t :: %__MODULE__{
          execution_state: atom() | :unknown,
          agent_stage: atom() | :unknown,
          progress: progress()
        }

  defstruct execution_state: :unknown, agent_stage: :unknown, progress: :unknown

  @spec new(term(), term(), term()) :: t()
  def new(execution_state, agent_stage, progress) do
    %__MODULE__{
      execution_state: atom_or_unknown(execution_state),
      agent_stage: atom_or_unknown(agent_stage),
      progress: progress(progress)
    }
  end

  defp atom_or_unknown(value) when is_atom(value) and not is_nil(value), do: value
  defp atom_or_unknown(_value), do: :unknown
  defp progress(value) when is_integer(value) and value in 0..100, do: value
  defp progress(_value), do: :unknown
end

defmodule Aiur.BuildOrder.Dependency do
  @moduledoc "A native dependency endpoint or an explicitly nonfetchable external reference."

  alias Aiur.{BuildOrder.Bounded, BuildOrder.Diagnostic, TrackerIdentity}

  @type t :: %__MODULE__{
          kind: :native | :external | :unknown,
          identity: TrackerIdentity.t() | nil,
          url: String.t() | nil,
          direction: :blocker_to_blocked,
          source_connection: :blocked_by | :blocking,
          blocker_identity: TrackerIdentity.t() | nil,
          blocked_identity: TrackerIdentity.t() | nil,
          diagnostics: [Diagnostic.t()]
        }

  defstruct kind: :external,
            identity: nil,
            url: nil,
            direction: :blocker_to_blocked,
            source_connection: :blocked_by,
            blocker_identity: nil,
            blocked_identity: nil,
            diagnostics: []

  @spec new(term(), term(), term()) :: t()
  def new(configured_identity, endpoint_identity, url),
    do: new(configured_identity, endpoint_identity, url, :blocked_by)

  @spec new(term(), term(), term(), term()) :: t()
  def new(configured_identity, endpoint_identity, url, source_connection) do
    source_connection = source_connection(source_connection)
    endpoints = directed_endpoints(configured_identity, endpoint_identity, source_connection)

    cond do
      native?(configured_identity, endpoint_identity) and foreign_url?(configured_identity, url) ->
        external(endpoint_identity, url, source_connection, endpoints)

      native?(configured_identity, endpoint_identity) ->
        native(endpoint_identity, url, source_connection, endpoints)

      external?(configured_identity, endpoint_identity, url) ->
        external(endpoint_identity, url, source_connection, endpoints)

      true ->
        unknown(url, source_connection, endpoints)
    end
  end

  @spec native?(term(), term()) :: boolean()
  def native?(configured, endpoint) do
    TrackerIdentity.joinable?(configured) and TrackerIdentity.joinable?(endpoint) and
      Bounded.same_repository?(configured, endpoint)
  end

  defp external?(configured, endpoint, url) do
    (TrackerIdentity.joinable?(endpoint) and not Bounded.same_repository?(configured, endpoint)) or
      foreign_url?(configured, url)
  end

  defp external(identity, url, source_connection, endpoints) do
    case Bounded.github_url(url) do
      {:ok, safe_url} ->
        %__MODULE__{
          identity: identity,
          url: safe_url,
          source_connection: source_connection,
          diagnostics: [Diagnostic.new(:external_dependency)]
        }
        |> Map.merge(endpoints)

      :error ->
        %__MODULE__{
          identity: identity,
          source_connection: source_connection,
          diagnostics: [
            Diagnostic.new(:external_dependency),
            Diagnostic.new(:unsafe_external_url)
          ]
        }
        |> Map.merge(endpoints)
    end
  end

  defp native(identity, url, source_connection, endpoints) do
    case Bounded.github_url(url) do
      {:ok, safe_url} ->
        %__MODULE__{kind: :native, identity: identity, url: safe_url, source_connection: source_connection}
        |> Map.merge(endpoints)

      :error ->
        %__MODULE__{
          kind: :native,
          identity: identity,
          source_connection: source_connection,
          diagnostics: [Diagnostic.new(:invalid_url)]
        }
        |> Map.merge(endpoints)
    end
  end

  defp unknown(url, source_connection, endpoints) do
    case Bounded.github_url(url) do
      {:ok, safe_url} ->
        %__MODULE__{
          kind: :unknown,
          url: safe_url,
          source_connection: source_connection,
          diagnostics: [Diagnostic.new(:invalid_identity)]
        }
        |> Map.merge(endpoints)

      :error ->
        %__MODULE__{
          kind: :unknown,
          source_connection: source_connection,
          diagnostics: [Diagnostic.new(:invalid_identity), Diagnostic.new(:invalid_url)]
        }
        |> Map.merge(endpoints)
    end
  end

  defp foreign_url?(configured, url) do
    case Bounded.github_issue_repository(url) do
      {:ok, repository} -> not Bounded.same_repository?(configured, repository)
      :error -> false
    end
  end

  defp source_connection(source) when source in [:blocked_by, :blocking], do: source
  defp source_connection(_source), do: :blocked_by

  defp directed_endpoints(configured, endpoint, :blocked_by),
    do: %{blocker_identity: endpoint, blocked_identity: configured}

  defp directed_endpoints(configured, endpoint, :blocking),
    do: %{blocker_identity: configured, blocked_identity: endpoint}
end

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
          diagnostics: [Diagnostic.t()]
        }

  defstruct identity: nil,
            title: "Untitled ticket",
            url: nil,
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
    {title, title_diagnostic} = title(Map.get(attributes, :title))
    {url, url_diagnostic} = url(Map.get(attributes, :url))
    identity = identity(Map.get(attributes, :identity))
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
      diagnostics: diagnostics
    }
  end

  def new(_attributes), do: new(%{})

  @spec structurally_valid?(term()) :: boolean()
  def structurally_valid?(%__MODULE__{identity: identity, diagnostics: diagnostics})
      when is_list(diagnostics) do
    TrackerIdentity.joinable?(identity) and
      Enum.all?(diagnostics, fn
        %Diagnostic{code: code} ->
          code not in [
            :connection_overflow,
            :invalid_identity,
            :invalid_dependency,
            :invalid_member,
            :invalid_lifecycle,
            :invalid_title,
            :invalid_url,
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
