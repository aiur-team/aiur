defmodule Aiur.GitHub.ResourceStore.Body do
  @moduledoc """
  ## Bodies must be JSON that round-trips unchanged

  A checkpointed body has to come back the shape it went in. `Jason` does not
  preserve atom map keys, atoms, tuples or structs, so a body containing any of
  them would work in memory and come back differently after a restart — a
  consumer matching `%{id: id}` would start raising with nothing to attribute it
  to. `put_resource/3` therefore **refuses** such a body, loudly, and holds no
  body at all rather than one that will change under the reader. GitHub REST
  responses are string-keyed JSON, so nothing a pipe deposits is affected.

  """

  require Logger
  # A single GitHub issue, pull request or comment body is a few kilobytes and
  # GitHub itself caps an issue body at 64 KiB, so nothing legitimate here comes
  # close. A resource that does is not cached at all: an entry that large would
  # be paid for on every checkpoint, and the reader falling back to a fetch is
  # exactly the pre-store behavior.
  @max_data_bytes 256 * 1024

  # What the store will hold as a body, decided once, at deposit time, against
  # exactly what the checkpoint can write back unchanged.
  #
  # A body that survives a restart in a *different shape* than it went in is
  # worse than no body: a consumer matching `%{id: id}` would work all day and
  # raise after the next restart, with nothing to attribute it to. GitHub REST
  # bodies are string-keyed JSON, so nothing legitimate is refused here — but
  # `put_resource/3` is a public writer and the units building on this store
  # deposit arbitrary bodies, so the refusal is explicit and loud rather than a
  # comment promising it cannot happen.
  #
  # Refused: an oversized body (paid for on every checkpoint) and a body JSON
  # cannot round-trip identically — an atom-keyed map, an atom, a tuple, a
  # struct, a pid. Refusing yields `nil`, so `deposit_etag/3` also declines the
  # validator and the next reader gets an unconditional `200` with a real body
  # instead of a `304` and nothing.
  # `:refused` and `{:ok, nil}` are kept apart deliberately. "I could not hold
  # what you sent" and "I am holding nothing" are different instructions to
  # `deposit/5`: the first must leave a good held body untouched, the second is a
  # caller depositing an empty answer.
  @spec storable_data(term(), term()) :: {:ok, term()} | :refused
  def storable_data(_key, nil), do: {:ok, nil}

  def storable_data(key, data) do
    cond do
      not json_round_trips?(data) ->
        Logger.error(
          "GitHub.ResourceStore refused a body for #{inspect(key)} that JSON cannot round-trip unchanged; " <>
            "deposit string-keyed JSON data or the entry would change shape across a restart"
        )

        :refused

      oversized?(data) ->
        Logger.warning("GitHub.ResourceStore refused an oversized body for #{inspect(key)}; any previously held body is kept")

        :refused

      true ->
        {:ok, data}
    end
  end

  # Only these shapes come back from `Jason.decode/1` identical to what went in.
  # A map is admitted solely when every key is a string, because that is the one
  # difference the checkpoint cannot preserve and cannot detect afterwards.
  @spec json_round_trips?(term()) :: boolean()
  def json_round_trips?(data) when is_binary(data) or is_number(data) or is_boolean(data) or is_nil(data), do: true
  def json_round_trips?(data) when is_list(data), do: Enum.all?(data, &json_round_trips?/1)
  def json_round_trips?(%_struct{}), do: false

  def json_round_trips?(data) when is_map(data) do
    Enum.all?(data, fn {key, value} -> is_binary(key) and json_round_trips?(value) end)
  end

  def json_round_trips?(_data), do: false

  # Measured as the JSON the checkpoint would have to write, for two reasons: it
  # is the size that actually costs something, and a body JSON cannot encode —
  # a tuple, a pid, a struct with no encoder — is refused here rather than
  # discovered later by a checkpoint that cannot render it.
  defp oversized?(data) do
    case Jason.encode(data) do
      {:ok, encoded} -> byte_size(encoded) > @max_data_bytes
      _error -> true
    end
  rescue
    _error -> true
  end
end
