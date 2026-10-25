defmodule Aiur.BuildOrder.EpicOverrides.Override do
  @moduledoc "A journaled general-epic assignment with actor and channel provenance."
  @enforce_keys [:number, :epic, :actor, :source, :confirmed, :at, :seq]
  defstruct @enforce_keys
  @type t :: %__MODULE__{number: pos_integer(), epic: String.t(), actor: String.t(), source: String.t(), confirmed: boolean(), at: DateTime.t(), seq: pos_integer()}

  @spec number(term()) :: {:ok, pos_integer()} | {:error, :invalid_epic_arguments}
  def number(value) when is_integer(value), do: number(Integer.to_string(value))

  def number(value) when is_binary(value) do
    if Regex.match?(~r/\A#?[1-9][0-9]{0,9}\z/, value), do: {:ok, value |> String.trim_leading("#") |> String.to_integer()}, else: {:error, :invalid_epic_arguments}
  end

  def number(_value), do: {:error, :invalid_epic_arguments}

  @spec provenance?(term()) :: boolean()
  def provenance?(%{actor: actor, source: source} = p) when is_binary(actor) and is_binary(source) do
    valid_actor = Regex.match?(~r/\A(?:cli:[A-Za-z0-9._-]{1,64}|agent:[1-9][0-9]{0,9})\z/, actor)
    map_size(p) == 2 and valid_actor and (source == actor or source == "backfill-agent")
  end

  def provenance?(_value), do: false

  @spec from_entry(term()) :: {:ok, map()} | {:error, atom()}
  def from_entry(%{"op" => op}) when op not in ["set", "clear"], do: {:error, :epic_overrides_version_unsupported}

  def from_entry(%{"op" => op, "number" => n, "seq" => seq, "actor" => actor, "source" => source, "at" => at} = entry)
      when op in ["set", "clear"] and is_integer(n) and is_integer(seq) and seq > 0 and is_binary(at) do
    with {:ok, ^n} <- number(n), true <- provenance?(%{actor: actor, source: source}), {:ok, time, 0} <- DateTime.from_iso8601(at), {:ok, value} <- decode_value(op, entry, time) do
      {:ok, %{op: op, number: n, seq: seq, actor: actor, source: source, at: time, value: value}}
    else
      _ -> {:error, :epic_overrides_corrupt}
    end
  end

  def from_entry(_entry), do: {:error, :epic_overrides_corrupt}

  defp decode_value("clear", _entry, _time), do: {:ok, nil}

  defp decode_value("set", %{"epic" => epic, "confirmed" => confirmed} = entry, time) when is_binary(epic) and is_boolean(confirmed) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, epic) and epic != "unsorted" and confirmed == (entry["source"] != "backfill-agent"),
      do: {:ok, struct!(__MODULE__, %{number: entry["number"], seq: entry["seq"], epic: epic, actor: entry["actor"], source: entry["source"], confirmed: confirmed, at: time})},
      else: {:error, :epic_overrides_corrupt}
  end

  defp decode_value(_op, _entry, _time), do: {:error, :epic_overrides_corrupt}

  @spec to_entry(t()) :: map()
  def to_entry(%__MODULE__{} = value), do: value |> Map.from_struct() |> Map.put(:op, "set") |> Map.update!(:at, &DateTime.to_iso8601/1)
end
