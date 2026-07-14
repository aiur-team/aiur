defmodule Aiur.BuildOrder.TicketDetail.Repository do
  @moduledoc false

  alias Aiur.BuildOrder.Bounded
  alias Aiur.BuildOrder.TicketDetail.Failure
  alias Aiur.{GitHub, TrackerIdentity}
  alias Aiur.GitHub.Issues

  @spec configured_repository(keyword()) :: {:ok, TrackerIdentity.repository()} | {:error, Failure.t()}
  def configured_repository(opts) do
    opts
    |> Keyword.get(:configured_repo, &GitHub.Config.configured_repo/0)
    |> configured_repository_result()
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
    with {:ok, {owner, repository}} <- Bounded.github_repository_components(owner, repository) do
      {:ok, {owner, repository}}
    else
      _ -> {:error, %Failure{kind: :configuration}}
    end
  end

  defp configured_repository_result(_repository), do: {:error, %Failure{kind: :configuration}}

  defp identity_matches_repository?(%TrackerIdentity{owner: owner, repository: repository}, configured_repository) do
    same_repository?({owner, repository}, configured_repository)
  end

  defp valid_repository_components(%TrackerIdentity{owner: owner, repository: repository}) do
    with {:ok, {_owner, _repository}} <- Bounded.github_repository_components(owner, repository) do
      :ok
    else
      _ -> :invalid_repository_component
    end
  end
end
