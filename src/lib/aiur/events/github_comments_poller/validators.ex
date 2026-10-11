defmodule Aiur.Events.GithubCommentsPoller.Validators do
  @moduledoc """
  ETag validators and `since` cursors for `Aiur.Events.GithubCommentsPoller`.

  Holds the store/provenance contract that decides what a `304` is worth, and
  the per-target cursor arithmetic the poll advances after publishing.
  """

  alias Aiur.Events.GithubKeys
  alias Aiur.GitHub.ResourceStore

  @doc false
  @spec normalize_since(term(), [String.t()], keyword()) :: map()
  def normalize_since(%{} = since_by_target, targets, opts) do
    default = default_since(opts)

    Map.new(targets, fn target ->
      {target, Map.get(since_by_target, target, default)}
    end)
  end

  def normalize_since(since, targets, _opts) when is_binary(since) do
    Map.new(targets, &{&1, since})
  end

  def normalize_since(_since, targets, opts) do
    default = default_since(opts)
    Map.new(targets, &{&1, default})
  end

  @doc false
  @spec normalize_etags(term(), [String.t()]) :: map()
  def normalize_etags(%{} = etags_by_target, targets) do
    Map.new(targets, fn target -> {target, Map.get(etags_by_target, target, %{})} end)
  end

  def normalize_etags(_etags, targets), do: Map.new(targets, &{&1, %{}})

  # The cycle's own map wins when it has an entry — it is the newest thing this
  # daemon knows. The store answers only for a target the in-memory map has
  # never seen, which after a restart is every target: without it the first
  # sweep of every boot re-reads every watched ticket's whole comment list at
  # full price, and restarts here are routine rather than rare.
  #
  # Where the validator came from is returned with it, because it decides what a
  # `304` against it is allowed to mean. A `:cycle` validator was minted by a
  # `200` this daemon already published, so "unchanged" is the truth and there is
  # nothing to recover. A `:store` validator may have outlived the publish it was
  # recorded beside, so "unchanged" alone is not enough — see `unchanged_list/2`.
  @doc false
  @spec request_etag(term(), term()) :: {String.t() | nil, :cycle | :store}
  def request_etag(_resource, etag) when is_binary(etag) and etag != "", do: {etag, :cycle}
  def request_etag(resource, _etag), do: {ResourceStore.etag(resource), :store}

  # The list *and* its validator, deposited together and only after the comments
  # in it were published.
  #
  # A validator on its own is not safe to hold here. It is an endpoint-level
  # validator, so GitHub answering `304` to it suppresses the whole list at once
  # and no per-comment reconciliation can see inside that answer. Recording one
  # before publishing therefore had a routine loss: `ResourceStore` starts before
  # `Publisher` and this poller, so on SIGTERM the poller dies first while the
  # store checkpoints last, and a comment read but not yet published came back to
  # a validator GitHub was right to answer `304` to and a store holding nothing.
  # No exception was needed for that.
  #
  # Depositing the body closes it from the other side: the next `304` is served
  # from the store and publishes exactly what a `200` would have, so a cycle that
  # dies between the read and the publish loses nothing, and the recovery costs
  # no request. Publishing first as well means the crash window contains no
  # validator at all, and the sweep after it is unconditional.
  #
  # A `nil` validator means the reader decided its validator cannot answer the
  # whole list (an issue-comment read that paginated — new comments land on the
  # last page, so a page-1 `304` would hide them; see website/docs-app/apis/github.md).
  # The store keeps a held validator for an unchanged body unless it is dropped
  # explicitly, so nil forces the drop: the next read must be unconditional
  # rather than answered by a stale page-1 `304`.
  @doc false
  @spec remember_list(term(), term(), String.t() | nil) :: String.t() | nil
  def remember_list(resource, comments, nil) when is_list(comments) do
    ResourceStore.put_resource(resource, comments, etag: nil, source: :poll)
    ResourceStore.drop_etag(resource)
    nil
  end

  def remember_list(resource, comments, etag) when is_list(comments) do
    ResourceStore.put_resource(resource, comments, etag: etag, source: :poll)
    etag
  end

  def remember_list(_resource, _comments, etag), do: etag

  # What a `304` is worth, decided by what the store holds and where the
  # validator came from.
  #
  #   * the list itself — republish it. Every comment in it is either already
  #     marked processed, and suppressed for free, or was never published, and
  #     is recovered. That is what makes a `304` produce the same events a `200`
  #     would have.
  #   * no list, but the validator is this daemon's own from an earlier cycle —
  #     nothing to recover: the `200` that minted it was published first. Keep
  #     the validator, because dropping it would make every steady-state cycle a
  #     full-price read, which is the cost this whole path exists to remove.
  #   * no list, and the validator came out of the store — it may have outlived
  #     the publish it was recorded beside, and it is an *endpoint* validator, so
  #     GitHub's `304` suppressed the entire list and no per-comment
  #     reconciliation can see inside it. Unusable.
  @doc false
  @spec unchanged_list(term(), :cycle | :store) :: {:ok, list()} | :nothing_to_recover | :unusable_validator
  def unchanged_list(resource, provenance) do
    case ResourceStore.fetch(resource) do
      {:ok, %{data: comments}} when is_list(comments) -> {:ok, comments}
      _other when provenance == :cycle -> :nothing_to_recover
      _other -> :unusable_validator
    end
  end

  # A `304` against a durable validator with no body behind it spent a request
  # and learned nothing recoverable. So the validator goes, here and in the
  # cycle's own map, and the next sweep reads unconditionally. That is the
  # reader's half of the store's validator/body contract; see
  # `Aiur.GitHub.ResourceStore`.
  @doc false
  @spec forget_validator(term()) :: nil
  def forget_validator(resource) do
    ResourceStore.drop_etag(resource)
    nil
  end

  @doc false
  @spec newest_comment_datetime([map()]) :: DateTime.t() | nil
  def newest_comment_datetime(comments) when is_list(comments) do
    Enum.reduce(comments, nil, fn comment, newest ->
      max_datetime(newest, comment_datetime(comment))
    end)
  end

  defp comment_datetime(comment) when is_map(comment) do
    comment
    |> Map.get("updated_at", Map.get(comment, "created_at"))
    |> parse_datetime()
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  @doc false
  @spec max_datetime(DateTime.t() | nil, DateTime.t() | nil) :: DateTime.t() | nil
  def max_datetime(nil, datetime), do: datetime
  def max_datetime(datetime, nil), do: datetime

  def max_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _ -> left
    end
  end

  @doc false
  @spec advance_since(term(), DateTime.t() | nil) :: term()
  def advance_since(since, nil), do: since

  def advance_since(_since, %DateTime{} = newest_seen_at) do
    newest_seen_at
    |> DateTime.add(-1, :second)
    |> DateTime.to_iso8601()
  end

  defp default_since(opts) do
    GithubKeys.boot_cutoff_iso8601(opts)
  end
end
