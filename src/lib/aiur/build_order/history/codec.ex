defmodule Aiur.BuildOrder.History.Codec do
  @moduledoc false
  alias Aiur.BuildOrder.History.Row
  alias Aiur.BuildOrder.Lifecycle
  @atoms ~w(unknown none open closed completed not_planned duplicate reopened labeled unlabeled label dispatch merged)a ++ Row.sources()
  @keys ~w(owner repository number label action at actor ref)a
  @strings ~w(title node_id agent_model agent_effort parent_version blocked_by_version actor)a

  @spec encode(Row.t()) :: map()
  def encode(row) do
    row |> Map.from_struct() |> Map.delete(:lifecycle) |> Map.merge(%{state: row.lifecycle.state, state_reason: row.lifecycle.state_reason}) |> encode_value()
  end

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(value) when is_map(value), do: Map.new(value, fn {k, v} -> {Atom.to_string(k), encode_field(k, v)} end)
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value) when is_boolean(value), do: value
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value
  # Preserve literal strings that otherwise collide with the version-1 sentinels.
  defp encode_field(key, value) when key in @strings and value in ["unknown", "none"], do: %{"value" => value}
  defp encode_field(_key, value), do: encode_value(value)

  @spec decode(term()) :: {:ok, Row.t()} | {:error, term()}
  def decode(value) when is_map(value) do
    keys = [:number, :observed_at, :sources, :state, :state_reason] ++ (Row.fields() -- [:lifecycle])

    with true <- Enum.sort(Map.keys(value)) == Enum.sort(Enum.map(keys, &Atom.to_string/1)),
         {:ok, fields} <- decode_fields(value, keys),
         lifecycle = %Lifecycle{state: fields.state, state_reason: fields.state_reason},
         true <- Row.valid?(:lifecycle, lifecycle) do
      {:ok, struct!(Row, fields |> Map.drop([:state, :state_reason]) |> Map.put(:lifecycle, lifecycle))}
    else
      {:error, field} -> {:error, {:invalid_row, Map.get(value, "number"), field}}
      _ -> {:error, {:invalid_row, Map.get(value, "number"), :shape}}
    end
  end

  def decode(_value), do: {:error, {:invalid_row, :unknown, :shape}}

  defp decode_fields(value, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      decoded = decode_value(key, Map.fetch!(value, Atom.to_string(key)))
      valid? = if key in [:state, :state_reason], do: decoded in @atoms, else: Row.valid?(key, decoded)
      if valid?, do: {:cont, {:ok, Map.put(acc, key, decoded)}}, else: {:halt, {:error, key}}
    end)
  end

  defp decode_value(key, value) when key in [:state, :state_reason, :action, :start_source, :end_source], do: atom(value)
  defp decode_value(key, %{"value" => value} = tagged) when key in @strings and map_size(tagged) == 1 and value in ["unknown", "none"], do: value

  defp decode_value(key, value) when value in ["unknown", "none"] do
    if Row.valid?(key, atom(value)) or key == :actor, do: atom(value), else: value
  end

  defp decode_value(:sources, value) when is_list(value), do: Enum.map(value, &atom/1)
  defp decode_value(key, value) when key in [:label_events, :sub_issues_added, :blocked_by] and is_list(value), do: Enum.map(value, &nested/1)
  defp decode_value(:parent, value) when is_map(value), do: nested(value)

  defp decode_value(key, value) do
    if key in (Row.dates() ++ [:observed_at, :at]), do: datetime(value), else: value
  end

  defp nested(value) when is_map(value) do
    Map.new(value, fn {key, v} ->
      k = Enum.find(@keys, &(Atom.to_string(&1) == key))
      {k, if(k == :ref, do: nested(v), else: decode_value(k, v))}
    end)
  end

  defp nested(value), do: value
  defp atom(value), do: Enum.find(@atoms, &(Atom.to_string(&1) == value))

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> :invalid
    end
  end

  defp datetime(_value), do: :invalid
end
