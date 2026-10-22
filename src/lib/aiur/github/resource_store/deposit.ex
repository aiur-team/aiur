defmodule Aiur.GitHub.ResourceStore.Deposit do
  @moduledoc """
  ## A refusal never destroys what is already held

  "I cannot hold what you sent" and "what you are holding is wrong" are
  different statements. An oversized or unencodable arrival is refused and the
  entry keeps its existing body, its version and its `fetched_at_ms` — throwing
  a good body away would make the next reader buy it again, and would leave the
  old validator beside no body at all.

  ## Versioning a read-modify-write: `:version` must be a function

  For `update_resource/3` on any resource whose ordering matters, pass
  `:version` as a **1-arity function of the merged body**, never a fixed string:

      ResourceStore.update_resource(key, &Map.put(&1, "labels", labels),
        version: fn body -> body["updated_at"] end
      )

  A static version is *structurally* wrong there, not merely risky. The caller
  computes it before the call, from a body a concurrent writer may have replaced
  by the time the merge re-runs inside the compare-and-swap — so a retry stamps
  the losing read's marker onto the winning read's content. Nothing raises. The
  body is simply labelled older than it is, and the next genuinely stale
  delivery is accepted against that wrong marker: the rollback the
  compare-and-swap exists to prevent, displaced one step into the metadata. The
  correct version cannot be known until the merge has run, and the merge only
  runs inside the swap, so the version has to be derived there too.

  ## A body with no version disarms the staleness guards downstream

  Worse than a missing marker is a `nil` one, and it is worth stating because
  the failure is silent at every level.
  `regression?/2` refuses an out-of-order
  delivery only when it has a binary marker on **both** sides, so a single
  version-less deposit does not weaken that guard for the resource — it switches
  it off, and every later late delivery lands. Deposit a version for anything a
  second pipe also writes. The store warns when a body is stored without one for
  an identity where ordering decides correctness (`@order_sensitive_types`),
  for the same reason an unlisted resource type is loud: the alternative is
  discovering it two units later, by accident.

  """

  require Logger
  alias Aiur.GitHub.ResourceStore.{Cas, Types}
  import Aiur.GitHub.ResourceStore.Body, only: [storable_data: 2]
  import Aiur.GitHub.ResourceStore.Storage, only: [now_ms: 0]
  import Aiur.GitHub.ResourceStore.Retention, only: [expired?: 1]
  import Aiur.GitHub.ResourceStore.Marks, only: [normalize_version: 1]
  @order_sensitive_types Types.order_sensitive_types()

  @type key :: Aiur.GitHub.ResourceStore.key()

  @spec put_resource(:ets.table(), key() | nil, term(), keyword()) :: :ok | {:error, term()}
  def put_resource(table, key, data, opts \\ [])

  def put_resource(_table, nil, _data, _opts), do: {:error, :invalid_key}

  def put_resource(table, key, data, opts) do
    update_resource(table, key, fn _held -> data end, opts)
  end

  @spec deposit_unless_older(:ets.table(), key() | nil, term(), keyword()) :: :ok | {:ok, :superseded} | {:error, term()}
  def deposit_unless_older(table, key, data, opts \\ [])
  def deposit_unless_older(_table, nil, _data, _opts), do: {:error, :invalid_key}

  def deposit_unless_older(table, key, data, opts) do
    version = resolve_version(Keyword.get(opts, :version), data)
    accept = fn _body, held -> if regression?(held.version, version), do: :unchanged, else: data end

    case update_resource(table, key, accept, opts) do
      :unchanged -> {:ok, :superseded}
      result -> result
    end
  end

  @spec regression?(term(), term()) :: boolean()
  def regression?(held, version) when is_binary(held) and is_binary(version), do: version < held
  def regression?(_held, _version), do: false

  @spec update_resource(:ets.table(), key() | nil, (term() -> term()) | (term(), map() -> term()), keyword()) :: :ok | :unchanged
  def update_resource(table, key, fun, opts \\ [])

  def update_resource(_table, nil, _fun, _opts), do: :ok

  def update_resource(table, key, fun, opts) when is_function(fun, 1) or is_function(fun, 2) do
    source = Keyword.get(opts, :source, :mutation)
    version = Keyword.get(opts, :version)

    Cas.update_reply(table, key, :ok, fn existing ->
      case merge(fun, existing) do
        :unchanged ->
          {:skip, :unchanged}

        merged ->
          storable = storable_data(key, merged)
          resolved = resolve_version(version, stored_body(storable))
          warn_unversioned(key, storable, resolved)
          {deposit(existing, storable, source, resolved, opts), :ok}
      end
    end)
  end

  defp merge(fun, existing) when is_function(fun, 1), do: fun.(held_body(existing))

  defp merge(fun, existing) do
    fun.(held_body(existing), %{
      version: Map.get(existing, :data_version),
      fetched_at_ms: Map.get(existing, :fetched_at_ms),
      etag: Map.get(existing, :etag)
    })
  end

  # A body with no version disarms every downstream staleness guard for that
  # resource, silently. `regression?/2` needs a
  # binary marker on *both* sides to refuse a late delivery, so one version-less
  # deposit makes every later out-of-order delivery for that key acceptable — the
  # guard is not weakened, it is switched off, and nothing says so.
  #
  # Only said out loud for the identities where ordering decides correctness: a
  # whole mutable resource whose state a stale delivery can roll back. An
  # endpoint list has no marker of its own and is not ordered against anything,
  # so warning about those would be noise that trains the reader to ignore this.
  defp warn_unversioned(key, {:ok, data}, nil) when not is_nil(data) do
    case key do
      {type, _owner, _repo, _id} when type in @order_sensitive_types ->
        Logger.warning(
          "GitHub.ResourceStore stored a body for #{inspect(key)} with no version; " <>
            "downstream staleness guards cannot refuse a late delivery for it"
        )

      _other ->
        :ok
    end
  end

  defp warn_unversioned(_key, _storable, _version), do: :ok

  # A refused arrival stores nothing, so a `:version` function is applied to
  # `nil` — it never describes the body the entry is still holding.
  defp stored_body({:ok, data}), do: data
  defp stored_body(:refused), do: nil

  # Resolved inside the caller's critical section, never before it, so a retry
  # re-derives the marker from the body that actually won the swap.
  defp resolve_version(version, body) when is_function(version, 1), do: normalize_version(version.(body))
  defp resolve_version(version, _body), do: normalize_version(version)

  # `fun` is handed what a reader would have been handed, which means an expired
  # body is `nil` here for the same reason `fetch/1` declines it: merging into a
  # body nothing has revalidated for three days would resurrect it under a fresh
  # `fetched_at_ms`.
  @spec held_body(map()) :: term()
  def held_body(entry) do
    case Map.get(entry, :data) do
      nil -> nil
      data -> if expired?(Map.get(entry, :fetched_at_ms) || 0), do: nil, else: data
    end
  end

  # A refused body leaves the entry's body exactly as it was.
  #
  # The refusal means "this arrival cannot be held", never "what you are holding
  # is wrong". Writing `nil` over a good body would destroy state the store
  # already paid for and force the next reader to buy it again — and it would do
  # that while keeping the old validator, which is the bodyless pair every other
  # path here refuses. `:fetched_at_ms` is left alone too: a deposit that stored
  # nothing has not refreshed anything, and stamping it now would tell the next
  # reader the held body is younger than it is.
  @spec deposit(map(), {:ok, term()} | :refused, atom(), String.t() | nil, keyword()) :: map()
  def deposit(entry, :refused, source, version, opts) do
    apply_processed_mark(entry, source, version, opts)
  end

  def deposit(entry, {:ok, data}, source, version, opts) do
    entry =
      entry
      |> Map.put(:data, data)
      |> Map.put(:data_version, version)
      |> Map.put(:fetched_at_ms, now_ms())
      |> stamp_full_body(opts)
      |> Map.put(:data_source, source)
      |> deposit_etag(Map.get(entry, :data), data, Keyword.get(opts, :etag))

    apply_processed_mark(entry, source, version, opts)
  end

  # `:full_body_at_ms` is when a whole body was last written or confirmed. A
  # `partial: true` write (a label merge that swaps one field of the held issue)
  # still moves `:fetched_at_ms`, because the labels it wrote are current, but
  # leaves this alone: every other field, `"state"` included, is exactly as old
  # as it was. A reader that needs a field the partial write did not touch
  # judges its age by this, never by `:fetched_at_ms` (#2714).
  defp stamp_full_body(entry, opts) do
    if Keyword.get(opts, :partial, false), do: entry, else: Map.put(entry, :full_body_at_ms, now_ms())
  end

  # `:version` moves only alongside `:processed_at_ms`. See the moduledoc:
  # advancing it on its own would suppress a version nothing has handled.
  defp apply_processed_mark(entry, source, version, opts) do
    cond do
      not Keyword.get(opts, :processed, false) ->
        entry

      is_nil(version) ->
        # A mark with no version suppresses on identity alone, which would
        # swallow the resource's next genuine change. Refused rather than
        # honoured, and said out loud, because the caller asked for something
        # that quietly breaks the guarantee the store is built on.
        Logger.warning("GitHub.ResourceStore ignored processed: true with no version; suppression needs a version")

        entry

      true ->
        entry
        |> Map.put(:processed_at_ms, now_ms())
        |> Map.put(:version, version)
        |> Map.put(:source, source)
    end
  end

  # A validator describes one exact body, so which validator an entry may keep
  # is decided by what happened to the body.
  #
  #   * a validator supplied with the deposit describes the body arriving with
  #     it — record it.
  #   * `:derive` — the writer has no validator of its own (a webhook delivery
  #     is that writer). The store derives a content-based one from the body
  #     being deposited, so the entry is never left "body, no validator" — the
  #     state in which `etag/1` answers nothing and every strict read pays full
  #     price. Because the derived validator is content-based it always
  #     describes the body beside it, so a stale validator beside a new body
  #     (finding #9) cannot happen; and because the body-unchanged clause below
  #     comes first, a re-delivery of an unchanged body keeps whatever validator
  #     is already held — a GitHub ETag a fetch recorded keeps earning its free
  #     `304`.
  #   * no validator supplied and the body is **unchanged** — the held validator
  #     still describes it, so keeping it keeps the next read free.
  #   * no validator supplied and the body **changed** — the held validator
  #     describes something the store no longer holds. Keeping it is not
  #     conservative, it is wrong: every later conditional read is then
  #     guaranteed to miss, so the entry can never earn a `304` again. A webhook
  #     delivery is exactly this case — it carries a fresh body and no validator
  #     of any kind.
  #   * no body at all — nothing to describe either way, so the held validator
  #     stands and only `change_validator/1` will hand it out.
  @spec deposit_etag(map(), term(), term(), term()) :: map()
  def deposit_etag(entry, _previous, nil, :derive), do: entry
  def deposit_etag(entry, previous, data, :derive) when previous == data, do: entry
  def deposit_etag(entry, _previous, data, :derive), do: Map.put(entry, :etag, derived_etag(data))

  def deposit_etag(entry, _previous, _data, etag) when is_binary(etag) and etag != "", do: Map.put(entry, :etag, etag)

  def deposit_etag(entry, _previous, nil, _etag), do: entry

  def deposit_etag(entry, previous, data, _etag) when previous == data, do: entry

  def deposit_etag(entry, _previous, _data, _etag), do: Map.delete(entry, :etag)

  # A content-based validator for a deposited body. Deterministic — the same
  # body yields the same validator — and specific to the body, so it can never
  # describe a different one. It is not a GitHub ETag: GitHub answers such a
  # validator with `200`, so its role is to keep the entry revalidatable (the
  # `etag/1` contract) rather than to replace the real ETag a fetch records.
  defp derived_etag(data) do
    case Jason.encode(data) do
      {:ok, json} -> ~s("sha256-#{Base.encode16(:crypto.hash(:sha256, json))}")
      _error -> nil
    end
  end
end
