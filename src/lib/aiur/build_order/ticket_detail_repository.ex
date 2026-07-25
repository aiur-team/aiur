defmodule Aiur.BuildOrder.TicketDetail.Repository do
  @moduledoc false

  alias Aiur.BuildOrder.Bounded
  alias Aiur.BuildOrder.TicketDetail.Failure
  alias Aiur.{GitHub, TrackerIdentity, WorkflowStore}
  alias Aiur.GitHub.{IssueRelationships, Issues}

  @spec configured_repository(keyword()) :: {:ok, TrackerIdentity.repository()} | {:error, Failure.t()}
  def configured_repository(opts) do
    opts
    |> Keyword.get(:configured_repo, &GitHub.Config.configured_repo/0)
    |> configured_repository_result()
  end

  @spec configured_repository_snapshot(keyword()) ::
          {:ok, TrackerIdentity.repository(), pos_integer() | :unknown} | {:error, Failure.t()}
  def configured_repository_snapshot(opts) do
    case Keyword.get(opts, :configuration_snapshot) do
      snapshot when is_function(snapshot, 0) -> configured_snapshot_result(snapshot)
      _snapshot -> configured_snapshot_from_options_or_store(opts)
    end
  end

  @spec fetchable_identity(TrackerIdentity.t(), keyword()) ::
          {:ok, TrackerIdentity.t(), TrackerIdentity.repository()} | {:error, Failure.t()}
  def fetchable_identity(%TrackerIdentity{} = identity, opts) do
    with {:ok, _identifier} <- Bounded.github_issue_identifier(identity.identifier),
         true <- TrackerIdentity.joinable?(identity),
         :github <- identity.kind,
         :ok <- valid_repository_components(identity),
         {:ok, configured_repository} <- configured_repository(opts),
         true <- identity_matches_repository?(identity, configured_repository) do
      {:ok, identity, configured_repository}
    else
      :invalid_repository_component -> {:error, %Failure{kind: :nonfetchable_repository}}
      false -> {:error, %Failure{kind: :nonfetchable_repository}}
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> {:error, %Failure{kind: :nonfetchable_repository}}
    end
  end

  def fetchable_identity(_identity, _opts), do: {:error, %Failure{kind: :nonfetchable_repository}}

  @spec fetch_issue(TrackerIdentity.t(), TrackerIdentity.repository(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_issue(identity, configured_repository, opts) do
    issue_opts =
      opts
      |> Keyword.take([:request_fun])
      |> Keyword.put(:repository, configured_repository)

    Issues.fetch_issue_raw(identity.identifier, issue_opts)
  end

  @spec fetch_linked_pull_requests(TrackerIdentity.t(), TrackerIdentity.repository(), keyword()) ::
          {:ok, %{nodes: [map()], truncated?: boolean()}} | {:error, term()}
  def fetch_linked_pull_requests(identity, configured_repository, opts) do
    case Keyword.get(opts, :relationship_reader) do
      reader when is_function(reader, 2) -> reader.(identity, configured_repository)
      _reader -> IssueRelationships.fetch_linked_pull_requests(identity, configured_repository, opts)
    end
  end

  @spec same_repository?(TrackerIdentity.repository(), TrackerIdentity.repository()) :: boolean()
  def same_repository?({owner, repository}, {configured_owner, configured_repository}) do
    String.downcase(owner) == String.downcase(configured_owner) and
      String.downcase(repository) == String.downcase(configured_repository)
  end

  defp configured_repository_result(repository) when is_function(repository, 0) do
    repository.() |> configured_repository_result()
  rescue
    _error -> {:error, %Failure{kind: :configuration}}
  catch
    _kind, _reason -> {:error, %Failure{kind: :configuration}}
  end

  defp configured_repository_result({:ok, repository}), do: configured_repository_result(repository)

  defp configured_repository_result({owner, repository}) when is_binary(owner) and is_binary(repository) do
    case Bounded.github_repository_components(owner, repository) do
      {:ok, {owner, repository}} -> {:ok, {owner, repository}}
      :error -> {:error, %Failure{kind: :configuration}}
    end
  end

  defp configured_repository_result(_repository), do: {:error, %Failure{kind: :configuration}}

  defp configured_snapshot_from_options_or_store(opts) do
    if Keyword.has_key?(opts, :configured_repo) do
      with {:ok, repository} <- configured_repository(opts) do
        {:ok, repository, configured_generation(opts)}
      end
    else
      configured_snapshot_from_store()
    end
  end

  defp configured_snapshot_from_store do
    with {:ok, %{config: config}, generation} <- WorkflowStore.current_with_generation(),
         repository when is_binary(repository) <- get_in(config, ["tracker", "github", "repo"]),
         [owner, name] <- String.split(String.trim(repository), "/"),
         {:ok, repository} <- configured_repository_result({owner, name}) do
      {:ok, repository, normalize_generation(generation)}
    else
      _ -> {:error, %Failure{kind: :configuration}}
    end
  end

  defp configured_snapshot_result(snapshot) do
    case snapshot.() do
      {repository, generation} ->
        with {:ok, repository} <- configured_repository_result(repository) do
          {:ok, repository, normalize_generation(generation)}
        end

      _ ->
        {:error, %Failure{kind: :configuration}}
    end
  rescue
    _error -> {:error, %Failure{kind: :configuration}}
  catch
    _kind, _reason -> {:error, %Failure{kind: :configuration}}
  end

  defp configured_generation(opts) do
    case Keyword.get(opts, :configuration_generation, 1) do
      generation when is_function(generation, 0) -> normalize_generation(generation.())
      generation -> normalize_generation(generation)
    end
  rescue
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp normalize_generation(generation) when is_integer(generation) and generation > 0, do: generation
  defp normalize_generation(_generation), do: :unknown

  defp identity_matches_repository?(%TrackerIdentity{owner: owner, repository: repository}, configured_repository) do
    same_repository?({owner, repository}, configured_repository)
  end

  defp valid_repository_components(%TrackerIdentity{owner: owner, repository: repository}) do
    case Bounded.github_repository_components(owner, repository) do
      {:ok, {_owner, _repository}} -> :ok
      :error -> :invalid_repository_component
    end
  end
end
