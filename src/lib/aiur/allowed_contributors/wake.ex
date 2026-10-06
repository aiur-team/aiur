defmodule Aiur.AllowedContributors.Wake do
  @moduledoc """
  Publishes the one Executor wake an accepted allowed-contributor issue earns.

  The topic is `ticket.<n>.issue.opened.allowed_contributor`, bound by default
  in `Aiur.ExecutorBindings` and projected to an identifier-only wake record by
  `Aiur.ExecutorWakeProjection`. The payload carries identifiers only (the
  author's numeric id, how they were admitted, and the allow-list commit) and
  never the issue's title or body: those are untrusted input the Executor reads
  from GitHub itself, under the `aiur-run` untrusted-content rule.

  Only a publish that reached a subscriber counts. Anything else is an error, so
  the caller defers the issue and retries it rather than auditing an accept for
  a wake nobody received.
  """

  alias Aiur.AllowedContributors.State

  @spec publish(State.t(), map(), String.t()) :: :ok | {:error, term()}
  def publish(%State{} = state, candidate, via) do
    payload = %{action: "opened", author_id: candidate.author_id, via: via, allowlist_sha: sha(state.snapshot)}
    topic = "ticket.#{candidate.number}.issue.opened.allowed_contributor"
    # No Publisher `dedup_key`: the durable seen set already gives one wake per
    # issue, and a dedup key would be recorded even by an undelivered publish,
    # so the deferred retry would come back `:deduped` and be counted as sent.
    case state.publish_fun.(topic, payload, bypass_contamination: true) do
      # Zero subscribers means nothing recorded the wake: retry on a later
      # sighting instead.
      {:ok, _id, 0} -> {:error, :no_subscribers}
      {:ok, _id, _subscribers} -> :ok
      other -> {:error, other}
    end
  rescue
    error -> {:error, {:publish_raised, Exception.message(error)}}
  end

  @doc "The allow-list commit a decision was made against, or `nil`."
  @spec sha(term()) :: String.t() | nil
  def sha(%{sha: sha}), do: sha
  def sha(_snapshot), do: nil
end
