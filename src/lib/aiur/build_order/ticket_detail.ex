defmodule Aiur.BuildOrder.TicketDetail do
  @moduledoc """
  Loads one bounded GitHub issue detail snapshot for a configured repository.

  The request identity is the authority boundary. A display number is used only
  after the identity has passed the configured-repository gate, and the GitHub
  response must prove the same provider node identity before its content is
  accepted.
  """

  alias Aiur.BuildOrder.TicketDetail.{Failure, Normalizer, Repository, Snapshot}
  alias Aiur.TrackerIdentity

  @type result :: {:ok, Snapshot.t()} | {:error, Failure.t()}

  @spec default_max_description_bytes() :: pos_integer()
  defdelegate default_max_description_bytes(), to: Normalizer

  @doc "Maximum provider Retry-After retained in a public detail failure, in seconds."
  @spec max_retry_after_seconds() :: pos_integer()
  defdelegate max_retry_after_seconds(), to: Normalizer

  @spec fetch(TrackerIdentity.t(), keyword()) :: result()
  def fetch(identity, opts \\ []) do
    with {:ok, identity, configured_repository} <- fetchable_identity(identity, opts),
         # The read cost — served, revalidated, or paid — is deliberately not
         # carried into the snapshot. A snapshot describes the ticket, not how
         # cheaply it arrived, and a test that wants to prove a refresh spent
         # nothing counts requests at the transport rather than trusting a label
         # the code under test wrote about itself.
         {:ok, raw_issue, _read_cost} <- Repository.fetch_issue(identity, configured_repository, opts),
         {:ok, relationships} <- Repository.fetch_linked_pull_requests(identity, configured_repository, opts),
         {:ok, snapshot} <- snapshot(identity, raw_issue, Keyword.put(opts, :relationships, relationships)) do
      {:ok, snapshot}
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, Normalizer.failure_from(reason)}
    end
  end

  @spec configured_repository(keyword()) :: {:ok, TrackerIdentity.repository()} | {:error, Failure.t()}
  defdelegate configured_repository(opts), to: Repository

  @spec configured_repository_snapshot(keyword()) ::
          {:ok, TrackerIdentity.repository(), pos_integer() | :unknown} | {:error, Failure.t()}
  defdelegate configured_repository_snapshot(opts), to: Repository

  @spec fetchable_identity(TrackerIdentity.t(), keyword()) ::
          {:ok, TrackerIdentity.t(), TrackerIdentity.repository()} | {:error, Failure.t()}
  def fetchable_identity(identity, opts \\ []), do: Repository.fetchable_identity(identity, opts)

  @spec snapshot(TrackerIdentity.t(), map(), keyword()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def snapshot(identity, raw_issue, opts \\ []), do: Normalizer.snapshot(identity, raw_issue, opts)
end
