defmodule Aiur.Commands.EventData do
  @moduledoc "Closed, bounded data for additive Command facts outside the v1 request snapshot."

  alias Aiur.Commands.RequestContent
  alias Aiur.Commands.Routing.FactData
  alias Aiur.DecisionEvent.Validation

  @routing_types FactData.types()

  @spec fact_types() :: [atom()]
  def fact_types, do: [:request_attributed] ++ @routing_types

  @spec normalize(atom(), term()) :: {:ok, map()} | {:error, term()}
  def normalize(:request_attributed, raw) when is_map(raw) do
    with {:ok, requester} <- normalize_requester(Validation.get(raw, :requester)),
         {:ok, origin} <- enum(Validation.get(raw, :origin), [:emit_event, :attention, :native_question, :executor_cli, :supervisor_api], :origin, true),
         {:ok, native} <- normalize_native(Validation.get(raw, :native)),
         {:ok, questions} <- questions(Validation.get(raw, :questions)),
         {:ok, short_label} <- Validation.bounded_optional(Validation.get(raw, :short_label), 40, :short_label) do
      {:ok, %{requester: requester, origin: origin, native: native, questions: questions, short_label: short_label}}
    end
  end

  def normalize(type, raw) when type in @routing_types and is_map(raw), do: FactData.normalize(type, raw)

  def normalize(_type, _raw), do: {:error, {:event_data, :invalid}}

  @spec to_json_safe(atom(), map()) :: map()
  def to_json_safe(type, data) when type in @routing_types, do: Aiur.JSONSafe.normalize(data)
  def to_json_safe(:request_attributed, data), do: json_safe(data)

  defp normalize_requester(nil), do: {:ok, nil}

  defp normalize_requester(raw) when is_map(raw) do
    with {:ok, kind} <- enum(Validation.get(raw, :kind), [:worker, :executor], :requester_kind),
         {:ok, strings} <- strings(raw, [:ticket, :session_ref, :executor_id, :harness]) do
      {:ok, Map.put(strings, :kind, kind)}
    end
  end

  defp normalize_requester(_raw), do: {:error, {:requester, :invalid_type}}

  defp normalize_native(nil), do: {:ok, nil}

  defp normalize_native(raw) when is_map(raw) do
    with {:ok, harness} <- enum(Validation.get(raw, :harness), [:codex, :claude], :native_harness),
         {:ok, native_ref} <- Validation.map_required_string(raw, :native_ref, 256),
         {:ok, strings} <- strings(raw, [:call_id, :turn_id]),
         {:ok, question_ids} <- question_ids(Validation.get(raw, :question_ids)),
         {:ok, hold} <- enum(Validation.get(raw, :hold), [:in_band, :deferred, :released], :hold) do
      {:ok, Map.merge(strings, %{harness: harness, native_ref: native_ref, question_ids: question_ids, hold: hold})}
    end
  end

  defp normalize_native(_raw), do: {:error, {:native, :invalid_type}}

  defp strings(raw, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Validation.bounded_optional(Validation.get(raw, key), 256, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp enum(value, allowed, field, optional \\ false) do
    cond do
      is_nil(value) and optional -> {:ok, nil}
      value in allowed -> {:ok, value}
      is_binary(value) -> enum(Enum.find(allowed, &(Atom.to_string(&1) == value)), allowed, field)
      true -> {:error, {field, :invalid_enum}}
    end
  end

  defp question_ids(nil), do: {:ok, []}

  defp question_ids(raw) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn value, {:ok, acc} ->
      case Validation.bounded_required(value, 256, :question_id) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        error -> {:halt, error}
      end
    end)
  end

  defp question_ids(_raw), do: {:error, {:question_ids, :invalid_type}}

  # Preserve pre-v2 attribution facts on replay; new questions have a question_id.
  defp questions(nil), do: {:ok, []}

  defp questions(raw) when is_list(raw) do
    cond do
      raw == [] -> {:ok, []}
      not Enum.all?(raw, &is_map/1) -> {:error, {:questions, :invalid_type}}
      Enum.all?(raw, &(not is_nil(Validation.get(&1, :question_id)))) -> RequestContent.normalize_questions(raw)
      true -> {:ok, raw}
    end
  end

  defp questions(_raw), do: {:error, {:questions, :invalid_type}}

  defp json_safe(value) when is_map(value), do: Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp json_safe(value), do: value
end
