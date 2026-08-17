defmodule Aiur.GitHub.CacheInspector.Entry do
  @moduledoc """
  One cache entry, normalised for display and stripped of anything secret.

  The store's own record is shaped for the store's job. This turns it into the
  record the debug page's third layer shows: a stable identity that survives in
  a URL, an age, a writer, whether a validator is held, and the payload.

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
    :version,
    :etag,
    :source,
    :writer,
    :age_ms,
    :freshness,
    :payload,
    writes: 0,
    validator?: false
  ]

  @type t :: %__MODULE__{}

  # The store records `source` in its own vocabulary. The page filters by the
  # four writers the design names, so unrecognised sources land in `:other`
  # rather than being silently dropped or coerced into a writer that did not
  # make the write.
  @writer_aliases %{
    mutation: :mutation,
    mutation_write_through: :mutation,
    write_through: :mutation,
    webhook: :webhook,
    delivery: :webhook,
    need: :need,
    need_driven: :need,
    fetch: :need,
    poll: :sweep,
    sweep: :sweep,
    safety_sweep: :sweep
  }

  @spec new(map(), DateTime.t(), map()) :: t()
  def new(raw, now, thresholds) when is_map(raw) do
    {resource_type, owner, repo, id} = identity_parts(raw)
    fetched_at = datetime(Map.get(raw, :fetched_at) || Map.get(raw, :processed_at_ms))
    age_ms = age(fetched_at, now)
    etag = Redactor.scrub(string(Map.get(raw, :etag)))

    %__MODULE__{
      identity: identity(resource_type, owner, repo, id),
      resource_type: resource_type,
      owner: owner,
      repo: repo,
      id: id,
      fetched_at: fetched_at,
      version: Redactor.scrub(string(Map.get(raw, :version))),
      etag: etag,
      validator?: is_binary(etag),
      source: Map.get(raw, :source),
      writer: writer(Map.get(raw, :source)),
      writes: integer(Map.get(raw, :writes)),
      age_ms: age_ms,
      freshness: freshness(age_ms, thresholds),
      payload: Redactor.redact(Map.get(raw, :payload))
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

  defp identity_parts(%{key: {resource_type, owner, repo, id}}), do: {resource_type, owner, repo, to_string(id)}

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

  # An entry with no `fetched_at` is not fresh and is not stale; its freshness
  # is unknown, and saying `:expired` would be a guess dressed as a fact.
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

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0
end
