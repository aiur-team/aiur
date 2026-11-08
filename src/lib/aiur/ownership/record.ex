defmodule Aiur.Ownership.Record do
  @moduledoc """
  The `owner.json` ownership record (S1), stored in the commit a
  `refs/aiur/owners/<ticket>` ref points at.

  `daemon_key` (the instance key) is required beside `gateway_id`, so two
  daemons on one machine never read each other's claims as their own.
  """

  @schema "aiur.ownership/v1"
  @fields ~w(schema repo ticket state gateway_id gateway_label daemon_key epoch previous_epoch actor reason at)a

  @enforce_keys @fields -- [:schema]
  # `note` is optional free text (a transfer's `--reason`); it is omitted from the bytes when nil.
  defstruct @fields ++ [note: nil]

  @type t :: %__MODULE__{
          schema: String.t(),
          repo: String.t(),
          ticket: String.t(),
          state: String.t(),
          gateway_id: String.t(),
          gateway_label: String.t(),
          daemon_key: String.t(),
          epoch: pos_integer(),
          previous_epoch: non_neg_integer(),
          actor: %{kind: String.t(), id: String.t()},
          reason: String.t(),
          at: String.t(),
          note: String.t() | nil
        }

  @doc "Validates `attrs` (atom keys) into a record."
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid, atom()}}
  def new(attrs) when is_map(attrs) do
    attrs = Map.put(attrs, :schema, @schema)

    with :ok <- validate(attrs) do
      {:ok, struct!(__MODULE__, Map.take(attrs, [:note | @fields]))}
    end
  end

  @doc "Deterministic bytes: S1 field order, no trailing newline."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = record) do
    fields =
      Enum.map(@fields, fn
        :actor -> {"actor", Jason.OrderedObject.new([{"kind", record.actor.kind}, {"id", record.actor.id}])}
        field -> {Atom.to_string(field), Map.fetch!(record, field)}
      end)

    fields = if record.note, do: fields ++ [{"note", record.note}], else: fields
    Jason.encode!(Jason.OrderedObject.new(fields))
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, %{"schema" => @schema} = map} -> map |> atomize() |> new()
      {:ok, %{"schema" => other}} -> {:error, {:unsupported_schema, other}}
      {:ok, _other} -> {:error, :not_a_record}
      {:error, error} -> {:error, {:json, error}}
    end
  end

  defp atomize(map) do
    actor = Map.get(map, "actor")
    actor = if is_map(actor), do: %{kind: actor["kind"], id: actor["id"]}, else: actor
    for field <- [:note | @fields] -- [:actor], into: %{actor: actor}, do: {field, Map.get(map, Atom.to_string(field))}
  end

  defp validate(attrs) do
    Enum.find_value(@fields ++ [:note], :ok, fn field ->
      if valid?(field, Map.get(attrs, field), attrs), do: nil, else: {:error, {:invalid, field}}
    end)
  end

  defp valid?(:schema, v, _), do: v == @schema
  defp valid?(:repo, v, _), do: is_binary(v) and Regex.match?(~r{\A[^/\s]+/[^/\s]+\z}, v)
  defp valid?(:ticket, v, _), do: is_binary(v) and Regex.match?(~r/\A(pr-)?[1-9][0-9]{0,9}\z/, v)
  defp valid?(:state, v, _), do: v in ["owned", "released"]
  defp valid?(:gateway_id, v, _), do: is_binary(v) and Regex.match?(~r/\A[a-z2-7]{26}\z/, v)
  defp valid?(:gateway_label, v, _), do: is_binary(v)
  defp valid?(:daemon_key, v, _), do: is_binary(v) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, v)
  defp valid?(:epoch, v, _), do: is_integer(v) and v >= 1
  defp valid?(:previous_epoch, v, %{epoch: e}), do: is_integer(e) and v == e - 1
  defp valid?(:actor, %{kind: k, id: id}, _), do: k in ["daemon", "human", "executor"] and is_binary(id)
  defp valid?(:actor, _, _), do: false
  defp valid?(:reason, v, _), do: v in ["dispatch", "transfer", "release", "migration"]
  defp valid?(:note, v, _), do: is_nil(v) or (is_binary(v) and String.length(v) in 1..500)
  defp valid?(:at, v, _), do: is_binary(v) and String.ends_with?(v, "Z") and match?({:ok, _, _}, DateTime.from_iso8601(v))
end
