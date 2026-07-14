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

  defp atom_or_unknown(value) when is_atom(value), do: value
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
          diagnostics: [Diagnostic.t()]
        }

  defstruct kind: :external, identity: nil, url: nil, diagnostics: []

  @spec new(term(), term(), term()) :: t()
  def new(configured_identity, endpoint_identity, url) do
    cond do
      native?(configured_identity, endpoint_identity) and foreign_url?(configured_identity, url) ->
        external(url)

      native?(configured_identity, endpoint_identity) ->
        native(endpoint_identity, url)

      external?(configured_identity, endpoint_identity, url) ->
        external(url)

      true ->
        unknown(url)
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

  defp external(url) do
    case Bounded.github_url(url) do
      {:ok, safe_url} ->
        %__MODULE__{url: safe_url, diagnostics: [Diagnostic.new(:external_dependency)]}

      :error ->
        %__MODULE__{
          diagnostics: [
            Diagnostic.new(:external_dependency),
            Diagnostic.new(:unsafe_external_url)
          ]
        }
    end
  end

  defp native(identity, url) do
    case Bounded.github_url(url) do
      {:ok, safe_url} ->
        %__MODULE__{kind: :native, identity: identity, url: safe_url}

      :error ->
        %__MODULE__{
          kind: :native,
          identity: identity,
          diagnostics: [Diagnostic.new(:invalid_url)]
        }
    end
  end

  defp unknown(url) do
    case Bounded.github_url(url) do
      {:ok, safe_url} ->
        %__MODULE__{kind: :unknown, url: safe_url, diagnostics: [Diagnostic.new(:invalid_identity)]}

      :error ->
        %__MODULE__{kind: :unknown, diagnostics: [Diagnostic.new(:invalid_identity), Diagnostic.new(:invalid_url)]}
    end
  end

  defp foreign_url?(configured, url) do
    case Bounded.github_issue_repository(url) do
      {:ok, repository} -> not Bounded.same_repository?(configured, repository)
      :error -> false
    end
  end
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
          dependencies: [Dependency.t()],
          diagnostics: [Diagnostic.t()]
        }

  defstruct identity: nil,
            title: "Untitled ticket",
            url: nil,
            metadata: %Metadata{},
            lifecycle: %Lifecycle{},
            activity: %Activity{},
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
        [identity_diagnostic(identity), title_diagnostic, url_diagnostic] ++ marker_diagnostics ++ dependency_diagnostics,
        &is_nil/1
      )

    %__MODULE__{
      identity: identity,
      title: title,
      url: url,
      metadata: metadata,
      lifecycle: lifecycle(attributes),
      activity: activity(attributes),
      dependencies: dependencies,
      diagnostics: diagnostics
    }
  end

  def new(_attributes), do: new(%{})

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
    do: Activity.new(Map.get(attributes, :execution_state), Map.get(attributes, :agent_stage), Map.get(attributes, :progress))

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
end
