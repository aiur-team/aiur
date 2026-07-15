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
    case Bounded.github_issue_url_for(url, identity) do
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
    case Bounded.github_issue_url_for(url, identity) do
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
