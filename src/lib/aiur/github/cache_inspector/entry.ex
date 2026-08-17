defmodule Aiur.GitHub.CacheInspector.Entry do
  @moduledoc """
  One cache entry, normalised for display and stripped of anything secret.

  The store's own record is shaped for the store's job. This turns it into the
  record the debug page's third layer shows: a stable identity that survives in
  a URL, an age, which writer deposited it, what validator and versions it
  holds, and whether it holds a body at all.

  ## Validator held, body absent, is its own state

  `Aiur.GitHub.ResourceStore.drop_data/1` removes the body and deliberately
  leaves the ETag. That is sanctioned — the validator still answers "has this
  changed?" cheaply — but it is *not* a cache hit. A reader that sends the
  stored ETag for a body the store does not hold gets a `304` and no data: a
  request paid for that returns nothing, and a read the operator expected to be
  free silently becomes a dropped one. That exact confusion was a P1 in the
  store foundation.

  So `body?` is carried separately from `validator?` and `bodyless?` is derived
  from both, rather than the page inferring "cached" from the presence of an
  ETag. An operator on this page asking "why did that read cost money" needs to
  see the difference, not reconstruct it.

  ## Two versions, kept apart

  `version` is the version some pipe *processed*; `data_version` is the version
  of the body currently held. The store keeps them apart on purpose, so this
  does too. Collapsing them here would put a number on screen that answers
  neither question.

  ## Redaction is applied here, not at the page

  Every value that leaves this module has been through
  `Aiur.GitHub.CacheInspector.Redactor`. Doing it at the boundary rather than in
  the template means a new field added to the store is redacted by default
  instead of when somebody remembers. A cached GitHub response can legitimately
  carry an installation token or an authorization header — the store holds
  response bodies precisely so a second consumer gets the data rather than a
  bare 304 — and a debug page is exactly the surface on which that would be
  pasted into a ticket as evidence.
  """

  alias Aiur.GitHub.CacheInspector.Redactor

  @enforce_keys [:identity, :resource_type]
  defstruct [
    :identity,
    :resource_type,
    :owner,
    :repo,
    :id,
    :fetched_at,
    :recorded_at,
    :processed_at,
    :version,
    :data_version,
    :etag,
    :source,
    :writer,
    :age_ms,
    :freshness,
    :payload,
    body?: false,
    validator?: false,
    bodyless?: false
  ]

  @type t :: %__MODULE__{}

  # The store documents its writer vocabulary as `:mutation`, `:webhook`,
  # `:poll` and `:fetch`; the design names the same four as mutation
  # write-through, webhook, safety sweep and need-driven fetch. Both spellings
  # are accepted and an unrecognised source lands in `:other` rather than being
  # dropped or coerced into a writer that did not make the write.
  @writer_aliases %{
    mutation: :mutation,
    mutation_write_through: :mutation,
    write_through: :mutation,
    webhook: :webhook,
    delivery: :webhook,
    fetch: :fetch,
    need: :fetch,
    need_driven: :fetch,
    poll: :poll,
    sweep: :poll,
    safety_sweep: :poll
  }

  @spec new(map(), DateTime.t(), map()) :: t()
  def new(raw, now, thresholds) when is_map(raw) do
    {resource_type, owner, repo, id} = identity_parts(raw)

    # Age is measured from when the *body* was recorded, never from
    # `recorded_at_ms`: every write touches that field, so a sweep re-recording
    # an unchanged validator would otherwise make a three-day-old body look like
    # it had just arrived. That is the same field `ResourceStore.fetch/1` judges
    # expiry on, so the page and the store agree about what "old" means.
    fetched_at = datetime(Map.get(raw, :fetched_at_ms))
    age_ms = age(fetched_at, now)
    etag = Redactor.scrub(string(Map.get(raw, :etag)))
    validator? = is_binary(etag)
    body? = body?(raw)

    %__MODULE__{
      identity: identity(resource_type, owner, repo, id),
      resource_type: resource_type,
      owner: owner,
      repo: repo,
      id: id,
      fetched_at: fetched_at,
      recorded_at: datetime(Map.get(raw, :recorded_at_ms)),
      processed_at: datetime(Map.get(raw, :processed_at_ms)),
      version: Redactor.scrub(string(Map.get(raw, :version))),
      data_version: Redactor.scrub(string(Map.get(raw, :data_version))),
      etag: etag,
      validator?: validator?,
      body?: body?,
      bodyless?: validator? and not body?,
      source: Map.get(raw, :source),
      writer: writer(Map.get(raw, :source)),
      age_ms: age_ms,
      freshness: freshness(age_ms, thresholds),
      payload: if(body?, do: Redactor.redact(Map.get(raw, :data)), else: nil)
    }
  end

  @doc """
  The URL-safe identity of an entry, so a deep link resolves after a restart.

  Built from the resource identity rather than from a position in a list: a list
  index would point at a different entry the moment anything was written, and
  the whole point of pasting the link into a ticket is that it still means the
  same thing tomorrow.
  """
  @spec identity(atom(), String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def identity(resource_type, owner, repo, id) do
    Enum.join([to_string(resource_type), owner || "-", repo || "-", id || "-"], ":")
  end

  @doc "Human text this entry should be searchable by."
  @spec searchable(t()) :: String.t()
  def searchable(%__MODULE__{} = entry) do
    [entry.identity, entry.owner, entry.repo, entry.id, to_string(entry.resource_type), entry.version]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  # The source has already answered this, and it answered by key presence rather
  # than truthiness. A resource whose cached body is `false`, `0` or `[]` is
  # still a body a reader can be served from.
  defp body?(%{data?: held}) when is_boolean(held), do: held
  defp body?(raw), do: Map.has_key?(raw, :data) and not is_nil(Map.get(raw, :data))

  defp identity_parts(%{key: {resource_type, owner, repo, id}}),
    do: {resource_type, string(owner), string(repo), to_string(id)}

  defp identity_parts(raw) do
    {
      Map.get(raw, :resource_type) || :unknown,
      string(Map.get(raw, :owner)),
      string(Map.get(raw, :repo)),
      string(Map.get(raw, :id))
    }
  end

  defp writer(source) when is_atom(source) and not is_nil(source), do: Map.get(@writer_aliases, source, :other)
  defp writer(source) when is_binary(source), do: source |> safe_atom() |> writer()
  defp writer(_source), do: :other

  defp safe_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :other
  end

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      _invalid -> nil
    end
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp datetime(_value), do: nil

  defp age(%DateTime{} = fetched_at, now), do: now |> DateTime.diff(fetched_at, :millisecond) |> max(0)
  defp age(_fetched_at, _now), do: nil

  # An entry with no body has no `fetched_at`, so its freshness is unknown
  # rather than expired. Calling it expired would be a guess dressed as a fact,
  # and calling it fresh would be the exact lie this page exists to prevent.
  defp freshness(nil, _thresholds), do: :unknown

  defp freshness(age_ms, %{stale_after_ms: stale, expired_after_ms: expired}) do
    cond do
      age_ms >= expired -> :expired
      age_ms >= stale -> :stale
      true -> :fresh
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(value) when is_integer(value), do: Integer.to_string(value)
  defp string(_value), do: nil
end
