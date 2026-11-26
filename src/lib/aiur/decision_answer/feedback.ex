defmodule Aiur.DecisionAnswer.Feedback do
  @moduledoc """
  Structured per-option feedback carried beside the chosen option of an answer.

  Each entry is `%{"option_id", "verdict", "reason"?}`. Verdicts are a closed
  set, option ids must belong to the Decision, and the whole list is bounded.
  """

  alias Aiur.SecretRedactor

  @verdicts ["like", "dislike"]
  @max_entries 20
  @reason_max 500
  @id_max 200

  @type entry :: %{required(String.t()) => String.t()}

  @doc "Validate untrusted feedback; `nil` and `[]` both normalize to `[]`."
  @spec normalize(term(), [map()], boolean()) :: {:ok, [entry()]} | {:error, {:feedback, term()}}
  def normalize(nil, _options, _unchecked?), do: {:ok, []}
  def normalize([], _options, _unchecked?), do: {:ok, []}

  def normalize(entries, _options, _unchecked?) when is_list(entries) and length(entries) > @max_entries,
    do: {:error, {:feedback, :too_large}}

  def normalize(entries, options, unchecked?) when is_list(entries) do
    ids = MapSet.new(options, &get(&1, :id))

    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case entry(entry, ids, unchecked?) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> unique(Enum.reverse(acc))
      error -> error
    end
  end

  def normalize(_other, _options, _unchecked?), do: {:error, {:feedback, :invalid_type}}

  @doc "Human-readable lines for the agent, one per entry."
  @spec render([entry()]) :: String.t()
  def render(feedback) do
    Enum.map_join(feedback, "\n", fn entry ->
      reason = if entry["reason"], do: " - #{entry["reason"]}", else: ""
      "- `#{entry["option_id"]}`: #{entry["verdict"]}#{reason}"
    end)
  end

  defp entry(entry, ids, unchecked?) when is_map(entry) do
    with {:ok, option_id} <- id(get(entry, :option_id)),
         :ok <- known(option_id, ids, unchecked?),
         {:ok, verdict} <- verdict(get(entry, :verdict)),
         {:ok, reason} <- reason(get(entry, :reason)) do
      base = %{"option_id" => option_id, "verdict" => verdict}
      {:ok, if(reason, do: Map.put(base, "reason", reason), else: base)}
    end
  end

  defp entry(_other, _ids, _unchecked?), do: {:error, {:feedback, :invalid_entry}}

  defp id(value) when is_binary(value) and value != "" and byte_size(value) <= @id_max, do: {:ok, value}
  defp id(_other), do: {:error, {:feedback, :option_id_invalid}}

  defp known(_id, _ids, true), do: :ok
  defp known(id, ids, false), do: if(MapSet.member?(ids, id), do: :ok, else: {:error, {:feedback, :unknown_option}})

  defp verdict(value) when value in @verdicts, do: {:ok, value}
  defp verdict(_other), do: {:error, {:feedback, :unknown_verdict}}

  defp reason(nil), do: {:ok, nil}

  defp reason(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > @reason_max -> {:error, {:feedback, :reason_too_long}}
      true -> {:ok, SecretRedactor.redact(trimmed)}
    end
  end

  defp reason(_other), do: {:error, {:feedback, :reason_invalid}}

  defp unique(entries) do
    if length(Enum.uniq_by(entries, & &1["option_id"])) == length(entries),
      do: {:ok, entries},
      else: {:error, {:feedback, :duplicate_option}}
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
