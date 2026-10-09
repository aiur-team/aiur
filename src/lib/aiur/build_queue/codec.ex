defmodule Aiur.BuildQueue.Codec do
  @moduledoc false
  alias Aiur.BuildQueue.Model
  alias Aiur.BuildQueue.Model.{Edge, Intent, Item, Latch, Queue}

  @schemas [
    {:queues, Queue,
     [
       id: :queue_id,
       name: :string,
       kind: {:enum, [:list, :build_order]},
       root: {:nullable, :positive},
       held: :boolean,
       start_trigger: {:default, {:enum, [nil | Aiur.StartTrigger.triggers()]}, nil},
       generation: :nonnegative,
       created_at: :datetime
     ]},
    {:items, Item,
     [
       issue_id: :issue_id,
       queue_id: :queue_id,
       position: {:nullable, :nonnegative},
       hold: {:enum, [nil, :operator, :external]},
       override: {:enum, [nil, :manual_promotion]},
       promoted_at: {:nullable, :datetime},
       added_at: :datetime
     ]},
    {:edges, Edge, [prerequisite: :issue_id, dependent: :issue_id, source: {:enum, [:list, :build_order, :native]}]},
    {:intents, Intent, [id: :string, issue_id: :issue_id, action: {:enum, [:promote, :withdraw, :mark, :unmark]}, target_labels: :strings, recorded_at_ms: :nonnegative, outcome: :outcome]},
    {:latches, Latch, [key: :key, opened_at_ms: :nonnegative, emitted?: {:default, :boolean, true}]}
  ]

  @spec encode(Model.t()) :: map()
  def encode(document) do
    Map.new(@schemas, fn {key, _module, fields} ->
      records = Enum.map(Map.fetch!(document, key), &encode_record(&1, fields))
      {Atom.to_string(key), records}
    end)
    |> Map.put("version", 1)
  end

  defp encode_record(record, fields) do
    Map.new(fields, fn {field, type} -> {Atom.to_string(field), encode_value(Map.fetch!(record, field), type)} end)
  end

  defp encode_value(nil, _type), do: nil
  defp encode_value(value, {:default, type, _}), do: encode_value(value, type)
  defp encode_value(value, {:nullable, type}), do: encode_value(value, type)
  defp encode_value(value, {:enum, _}), do: Atom.to_string(value)
  defp encode_value(value, :datetime), do: DateTime.to_iso8601(value)
  defp encode_value(:ok, :outcome), do: "ok"
  defp encode_value({:error, reason}, :outcome), do: %{"error" => encode_term(reason)}
  defp encode_value({_, _} = key, :key), do: encode_term(key)
  defp encode_value(value, _type), do: value

  # Opaque error terms and latch identities preserve tuples without creating atoms on read.
  defp encode_term(value), do: value |> :erlang.term_to_binary() |> Base.encode64()

  @spec decode(term()) :: {:ok, Model.t()} | {:error, {:unsupported_version, term()} | {:invalid, list()}}
  def decode(%{"version" => 1} = document) do
    Enum.reduce_while(@schemas, {:ok, %{}}, fn {key, module, fields}, {:ok, acc} ->
      path = [Atom.to_string(key)]

      case decode_records(Map.get(document, hd(path)), module, fields, path) do
        {:ok, records} -> {:cont, {:ok, Map.put(acc, key, records)}}
        error -> {:halt, error}
      end
    end)
    |> validate_positions()
  end

  def decode(%{"version" => version}), do: {:error, {:unsupported_version, version}}
  def decode(%{}), do: invalid(["version"])
  def decode(_), do: invalid([])

  defp validate_positions({:ok, document}) do
    kinds = Map.new(document.queues, &{&1.id, &1.kind})

    document.items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, document}, fn {item, index}, acc ->
      case {Map.get(kinds, item.queue_id), item.position} do
        {:list, position} when is_integer(position) -> {:cont, acc}
        {:build_order, nil} -> {:cont, acc}
        {nil, _} -> {:halt, invalid(["items", index, "queue_id"])}
        _ -> {:halt, invalid(["items", index, "position"])}
      end
    end)
  end

  defp validate_positions(error), do: error

  defp decode_records(records, module, fields, path) do
    if proper_list?(records), do: decode_list(records, module, fields, path), else: invalid(path)
  end

  defp decode_list(records, module, fields, path) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {record, index}, {:ok, acc} ->
      case decode_record(record, module, fields, path ++ [index]) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_records()
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
  defp reverse_records({:ok, records}), do: {:ok, Enum.reverse(records)}
  defp reverse_records(error), do: error

  defp decode_record(record, module, fields, path) when is_map(record) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {field, type}, {:ok, acc} ->
      field_path = path ++ [Atom.to_string(field)]

      with {:ok, value} <- fetch_field(record, field, type),
           {:ok, decoded} <- decode_value(value, type) do
        {:cont, {:ok, Map.put(acc, field, decoded)}}
      else
        _ -> {:halt, invalid(field_path)}
      end
    end)
    |> build_record(module)
  end

  defp decode_record(_, _, _, path), do: invalid(path)
  defp build_record({:ok, fields}, module), do: {:ok, struct!(module, fields)}
  defp build_record(error, _module), do: error

  # Older latches predate retry tracking and represent already-open attentions.
  defp fetch_field(record, field, {:default, _, default}), do: {:ok, Map.get(record, Atom.to_string(field), default)}
  defp fetch_field(record, field, _), do: Map.fetch(record, Atom.to_string(field))

  defp decode_value(value, {:default, type, _}), do: decode_value(value, type)

  defp decode_value(nil, {:nullable, _}), do: {:ok, nil}
  defp decode_value(value, {:nullable, type}), do: decode_value(value, type)

  defp decode_value(value, {:enum, allowed}) do
    case Enum.find(allowed, :invalid, &(encode_value(&1, {:enum, allowed}) == value)) do
      :invalid -> :error
      atom -> {:ok, atom}
    end
  end

  defp decode_value(value, :string) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  defp decode_value(value, :boolean) when is_boolean(value), do: {:ok, value}
  defp decode_value(value, :positive) when is_integer(value) and value > 0, do: {:ok, value}
  defp decode_value(value, :nonnegative) when is_integer(value) and value >= 0, do: {:ok, value}
  defp decode_value(value, :queue_id) when is_binary(value), do: if(Regex.match?(~r/\Aq-[0-9a-f]{4}\z/, value), do: {:ok, value}, else: :error)
  defp decode_value(value, :issue_id) when is_binary(value), do: if(Regex.match?(~r/\A[1-9][0-9]*\z/, value), do: {:ok, value}, else: :error)
  defp decode_value(value, :strings) when is_list(value), do: if(proper_list?(value) and Enum.all?(value, &(is_binary(&1) and &1 != "")), do: {:ok, value}, else: :error)

  defp decode_value(value, :datetime) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp decode_value(nil, :outcome), do: {:ok, nil}
  defp decode_value("ok", :outcome), do: {:ok, :ok}

  defp decode_value(%{"error" => value}, :outcome) do
    with {:ok, reason} <- decode_term(value), do: {:ok, {:error, reason}}
  end

  defp decode_value(value, :key) do
    case decode_term(value) do
      {:ok, {_, _} = key} -> {:ok, key}
      _ -> :error
    end
  end

  defp decode_value(_, _), do: :error

  defp decode_term(value) when is_binary(value) do
    with {:ok, binary} <- Base.decode64(value),
         {term, used} <- :erlang.binary_to_term(binary, [:safe, :used]),
         true <- used == byte_size(binary) do
      {:ok, term}
    end
  rescue
    ArgumentError -> :error
  end

  defp decode_term(_), do: :error
  defp invalid(path), do: {:error, {:invalid, path}}
end
