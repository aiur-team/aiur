defmodule Aiur.BuildOrder.GitHubGraph.Endpoint do
  @moduledoc false

  alias Aiur.{BuildOrder.Bounded, BuildOrder.Diagnostic, BuildOrder.RootSummary, TrackerIdentity}

  @spec node_identity(term(), {String.t(), String.t()}) :: {TrackerIdentity.t() | nil, Diagnostic.t() | nil}
  def node_identity(node, repository) do
    case endpoint_identity(node, repository) do
      {nil, diagnostic} ->
        {nil, diagnostic}

      {%TrackerIdentity{} = identity, diagnostic} ->
        if same_repository?(identity, repository) do
          {identity, diagnostic}
        else
          {nil, Diagnostic.new(:invalid_identity)}
        end
    end
  end

  @spec endpoint_identity(term(), {String.t(), String.t()}) :: {TrackerIdentity.t() | nil, Diagnostic.t() | nil}
  def endpoint_identity(node, fallback_repository) when is_map(node) do
    with {:ok, {owner, name}} <- repository_from_node(node, fallback_repository),
         {:ok, identity} <- TrackerIdentity.from_github(endpoint_fields(node), {owner, name}, {owner, name}) do
      {identity, nil}
    else
      _ -> {nil, Diagnostic.new(:invalid_identity)}
    end
  end

  def endpoint_identity(_node, _fallback_repository), do: {nil, Diagnostic.new(:invalid_identity)}

  @spec parent_identity(term(), {String.t(), String.t()}) :: {TrackerIdentity.t() | nil, Diagnostic.t() | nil}
  def parent_identity(node, repository) when is_map(node) do
    case Map.fetch(node, "parent") do
      {:ok, nil} -> {nil, nil}
      {:ok, parent} -> endpoint_identity(parent, repository)
      :error -> {nil, Diagnostic.new(:invalid_identity)}
    end
  end

  def parent_identity(_node, _repository), do: {nil, Diagnostic.new(:invalid_identity)}

  @spec direct_parent_diagnostic(term(), term(), term()) :: Diagnostic.t() | nil
  def direct_parent_diagnostic(
        %TrackerIdentity{} = parent,
        parent_node,
        %RootSummary{identity: %TrackerIdentity{} = root, url: root_url}
      ) do
    cond do
      not same?(parent, root) -> Diagnostic.new(:invalid_member)
      locator_matches?(parent, endpoint_url(parent_node), %{identity: root, url: root_url}) -> nil
      true -> Diagnostic.new(:invalid_endpoint_locator)
    end
  end

  def direct_parent_diagnostic(_parent, _parent_node, _root), do: Diagnostic.new(:invalid_member)

  @spec locator_matches?(term(), term(), term()) :: boolean()
  def locator_matches?(
        %TrackerIdentity{} = endpoint,
        endpoint_url,
        %{identity: %TrackerIdentity{} = canonical, url: canonical_url}
      ) do
    endpoint.database_id == canonical.database_id and
      endpoint.identifier == canonical.identifier and
      same_issue_url?(endpoint_url, endpoint, canonical_url)
  end

  def locator_matches?(_endpoint, _endpoint_url, _canonical), do: false

  @spec same?(term(), term()) :: boolean()
  def same?(left, right) do
    case {key(left), key(right)} do
      {{:github, _, _, _} = left_key, {:github, _, _, _} = right_key} -> left_key == right_key
      _ -> false
    end
  end

  @spec key(term()) :: {:github, String.t(), String.t(), String.t()} | nil
  def key(identity), do: TrackerIdentity.github_key(identity)

  defp endpoint_fields(node) do
    %{
      "node_id" => Map.get(node, "id"),
      "database_id" => Map.get(node, "databaseId"),
      "number" => Map.get(node, "number"),
      "repository" => Map.get(node, "repository")
    }
  end

  defp repository_from_node(%{"repository" => %{"name" => repository, "owner" => %{"login" => owner}}}, _fallback)
       when is_binary(owner) and is_binary(repository),
       do: {:ok, {owner, repository}}

  defp repository_from_node(_node, _fallback), do: {:error, :missing_repository_identity}

  defp same_repository?(
         %TrackerIdentity{owner: owner, repository: repository},
         {expected_owner, expected_repository}
       ) do
    String.downcase(owner) == String.downcase(expected_owner) and
      String.downcase(repository) == String.downcase(expected_repository)
  end

  defp same_repository?(_identity, _repository), do: false
  defp endpoint_url(node) when is_map(node), do: Map.get(node, "url")
  defp endpoint_url(_node), do: nil

  defp same_issue_url?(endpoint_url, endpoint, canonical_url) do
    with {:ok, endpoint_url} <- Bounded.github_issue_url_for(endpoint_url, endpoint),
         {:ok, endpoint_reference} <- Bounded.github_issue_reference(endpoint_url),
         {:ok, canonical_reference} <- Bounded.github_issue_reference(canonical_url) do
      endpoint_reference.kind == canonical_reference.kind and
        endpoint_reference.identifier == canonical_reference.identifier and
        Bounded.same_repository?(endpoint_reference, canonical_reference)
    else
      _ -> false
    end
  end
end
