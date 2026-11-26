defmodule Aiur.GitHub.ResourceStore.Reads do
  @moduledoc """
  ## Holding the resource, not only the validator

  An entry may also hold the resource's own `:data` — the object GitHub
  returned. A validator alone is not enough to satisfy a second consumer: an
  ETag shared without the body earns that consumer a `304` and no data, which
  converts a duplicate fetch into a dropped read. The body is what makes a
  reader able to answer without spending.

  `put_resource/3` is how a writer deposits one, and every write that changes
  what a reader could observe publishes a `Aiur.GitHub.ResourceEvents` change
  event to the subscribers of that resource, of its type in that repository, and
  of its type anywhere. That is what lets a view re-render off somebody else's
  write instead of paying for a read of its own.

  ## The validator/body contract — read this before adding a reader

  A validator and a body are separable, and the separation is what makes a `304` dangerous. Three states exist and each one binds the reader differently:

    * **body + validator** — the normal state after `put_resource/3`. A `304`
      means "what you hold is current": serve the held body and publish exactly
      what a `200` would have. This is the only state in which a conditional
      request is free *and* answers the question.
    * **validator, no body** — legitimate and deliberately reachable.
      `put_etag/2` records one, and `drop_data/1` removes a body while leaving
      the validator in place on purpose. A reader in this state that sends
      `If-None-Match` and is answered `304` has **spent a request and learned
      nothing**, and has to read again unconditionally: two requests where one
      was needed. **So the store does not offer this validator to a reader of
      bodies at all.** `etag/1` answers exactly when `fetch/1` answers, and a
      reader that genuinely only wants change detection asks
      `change_validator/1` by name and accepts that a `304` hands it nothing.
      That is enforcement rather than instruction, because the raw accessor was
      an invitation and two call sites took it.
    * **body, no validator** — a deposit whose writer had no ETag for a body
      that changed, or a validator the entry lost for the reason above. Costs
      one full-price read. Always safe.

  Two rules keep those states honest, both enforced rather than documented:

    * **A validator is never recorded for a body the store refused**, at deposit
      time *or* at checkpoint time. See `deposit_etag/4` and `encode_fields/2`.
    * **A validator never outlives the body it describes.** A deposit that
      supplies no validator keeps the held one only while the body is unchanged;
      a *different* body discards it, because a validator that describes
      something the store no longer holds guarantees every later conditional
      read misses — the entry could never earn a `304` again. A webhook delivery
      is exactly that case: a fresh body and no validator of any kind.

  """

  alias Aiur.GitHub.MembershipAccess
  alias Aiur.GitHub.ResourceStore.Types
  import Aiur.GitHub.ResourceStore.Storage, only: [lookup: 2, with_table: 3]
  import Aiur.GitHub.ResourceStore.Retention, only: [expired?: 1]
  @resource_types Types.resource_types()

  @type key :: Aiur.GitHub.ResourceStore.key()
  @type resource_type :: Aiur.GitHub.ResourceStore.resource_type()
  @type entry :: Aiur.GitHub.ResourceStore.entry()

  @spec etag(:ets.table(), key() | nil) :: String.t() | nil
  def etag(_table, nil), do: nil

  def etag(table, key) do
    case fetch(table, key) do
      {:ok, %{etag: etag}} when is_binary(etag) and etag != "" -> etag
      _other -> nil
    end
  end

  @spec change_validator(:ets.table(), key() | nil) :: String.t() | nil
  def change_validator(_table, nil), do: nil

  def change_validator(table, key) do
    case lookup(table, key) do
      %{etag: etag} = entry when is_binary(etag) and etag != "" ->
        if expired?(Map.get(entry, :recorded_at_ms) || 0), do: nil, else: etag

      _other ->
        nil
    end
  end

  @spec fetch(:ets.table(), key() | nil) :: {:ok, entry()} | :miss
  def fetch(_table, nil), do: :miss

  def fetch(table, key) do
    case lookup(table, key) do
      %{data: data} = entry when not is_nil(data) ->
        # Judged on when the *body* was recorded, never on `:recorded_at_ms`:
        # every write touches that field, so a sweep re-recording an unchanged
        # validator would keep a three-day-old body servable forever.
        if expired?(Map.get(entry, :fetched_at_ms) || 0) do
          :miss
        else
          {:ok,
           %{
             data: data,
             version: Map.get(entry, :data_version),
             # The pipe that deposited *this body*. Kept apart from `:source`,
             # which records the pipe that last marked the resource processed:
             # one deposit and one mark used to overwrite each other's answer,
             # so a reader asking "where did this body come from" could be told
             # about a mark instead. Falls back for entries written before the
             # split.
             source: Map.get(entry, :data_source) || Map.get(entry, :source),
             fetched_at_ms: Map.get(entry, :fetched_at_ms),
             # When a whole body was last written or confirmed; `nil` for an
             # entry recorded before the field existed. See `stamp_full_body/2`.
             full_body_at_ms: Map.get(entry, :full_body_at_ms),
             etag: Map.get(entry, :etag)
           }}
        end

      _other ->
        :miss
    end
  end

  @spec data(:ets.table(), key() | nil) :: term()
  def data(table, key) do
    case fetch(table, key) do
      {:ok, %{data: data}} -> data
      :miss -> nil
    end
  end

  @spec list_type(:ets.table(), resource_type(), String.t() | nil) :: [{key(), term()}]
  def list_type(table, type, full_name) when is_atom(type) and is_binary(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] when owner != "" and repo != "" and type in @resource_types ->
        # `match_object/2` matches whole stored objects (`{key, entry}`), so the
        # pattern wraps the key in the tuple that is actually stored.
        pattern = {{type, String.downcase(owner), String.downcase(repo), :_}, :_}

        MembershipAccess.run(type, [], fn -> read_type_entries(table, pattern) end)

      _other ->
        []
    end
  end

  def list_type(_table, _type, _full_name), do: []

  defp read_type_entries(table, pattern) do
    with_table(table, [], fn table -> list_type_entries(table, pattern) end)
  end

  defp list_type_entries(table, pattern) do
    table
    |> :ets.match_object(pattern)
    |> Enum.flat_map(&type_entry/1)
  end

  defp type_entry({key, entry}) do
    case held_entry(entry) do
      nil -> []
      data -> [{key, data}]
    end
  end

  # The same expiry rule `fetch/1` applies, so a projection rebuilding from
  # `list_type/2` never serves a body the store itself would have declined.
  defp held_entry(entry) do
    case Map.get(entry, :data) do
      nil ->
        nil

      data ->
        if expired?(Map.get(entry, :fetched_at_ms) || 0), do: nil, else: data
    end
  end
end
