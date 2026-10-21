defmodule Aiur.GitHub.ResourceStore.Validators do
  @moduledoc """
  Internal validators operations for `Aiur.GitHub.ResourceStore`.
  """

  alias Aiur.GitHub.ResourceStore.Cas
  import Aiur.GitHub.ResourceStore.Deposit, only: [held_body: 1, deposit_etag: 4]
  import Aiur.GitHub.ResourceStore.Storage, only: [now_ms: 0]

  @type key :: Aiur.GitHub.ResourceStore.key()

  @spec put_etag(:ets.table(), key() | nil, String.t() | nil, String.t() | nil | :any) :: :ok
  def put_etag(table, key, etag, previous \\ :any)
  def put_etag(_table, nil, _etag, _previous), do: :ok
  def put_etag(_table, _key, etag, _previous) when not is_binary(etag) or etag == "", do: :ok

  def put_etag(table, key, etag, previous) do
    Cas.update_reply(table, key, :ok, fn entry -> if previous in [:any, Map.get(entry, :etag)], do: {Map.put(entry, :etag, etag), :ok}, else: {:skip, :ok} end)
  end

  @spec revalidate(:ets.table(), key() | nil, term(), String.t() | nil) :: :confirmed | :superseded | :miss
  def revalidate(table, key, confirmed_data, etag)

  def revalidate(_table, nil, _confirmed_data, _etag), do: :miss

  def revalidate(table, key, confirmed_data, etag) do
    Cas.update_reply(table, key, :miss, fn existing ->
      case held_body(existing) do
        nil ->
          {existing, :miss}

        ^confirmed_data ->
          # One rule, one helper, both callers: a validator may only sit beside
          # the body it describes. Here the body is by definition unchanged —
          # that is what this clause matched on — so the validator this `304`
          # confirmed is installed. A deposit reaches the same helper from the
          # other direction and discards a held validator when the body moved.
          {existing
           |> Map.put(:fetched_at_ms, now_ms())
           |> Map.put(:full_body_at_ms, now_ms())
           |> deposit_etag(confirmed_data, confirmed_data, etag), :confirmed}

        _newer ->
          {existing, :superseded}
      end
    end)
  end

  @spec drop_data(:ets.table(), key() | nil) :: :ok
  def drop_data(_table, nil), do: :ok

  def drop_data(table, key) do
    Cas.update(table, key, fn entry -> entry |> Map.delete(:data) |> Map.delete(:data_version) end)
  end

  @spec drop_etag(:ets.table(), key() | nil) :: :ok
  def drop_etag(_table, nil), do: :ok

  def drop_etag(table, key) do
    # Decided *inside* the swap, on the raw `:etag` field, and both halves of that
    # matter.
    #
    # Inside, because the check "is there a validator to forget" and the act of
    # forgetting it used to be two operations with a whole read/write gap between
    # them: a concurrent `put_etag/2` landing in the gap was answered `:ok` by a
    # call that then dropped nothing, and a validator the caller was told had been
    # forgotten stayed and repeated the same empty `304` every cycle. `:skip` is
    # what lets the swap decline to write at all, so forgetting a validator
    # nothing holds still does not create an empty entry for the key.
    #
    # On the raw field, because `etag/1` deliberately answers only when a body is
    # held — so asking it here made this function a no-op in the one state it
    # exists for. A reader answered `304` for a key the store holds *no* body for
    # is the bodyless-validator case; that is precisely the validator that has to
    # go.
    Cas.update_reply(table, key, :ok, fn entry ->
      if is_nil(Map.get(entry, :etag)) do
        {:skip, :ok}
      else
        {Map.delete(entry, :etag), :ok}
      end
    end)
  end
end
