defmodule AiurWeb.EventsQuery do
  @moduledoc false
  alias Aiur.Events.{Catalog, Export}

  @spec parse(map()) :: {:ok, map()} | {:error, atom()}
  def parse(params) do
    with {:ok, limit} <- integer(params, "limit", 100, 1, 500, :invalid_limit),
         {:ok, after_seq} <- integer(params, "after", Export.status().head_seq, 0, :infinity, :invalid_cursor),
         {:ok, patterns} <- patterns(params),
         {:ok, opts} <- epoch(params) do
      {:ok, %{after: after_seq, limit: limit, patterns: patterns, opts: opts}}
    end
  end

  @spec join(map()) :: {:ok, map()} | {:error, atom()}
  def join(params) when is_map(params) do
    with {:ok, after_seq} <- join_cursor(params["after"]),
         {:ok, patterns} <- join_topics(params["topics"]),
         {:ok, opts} <- join_epoch(params["epoch"]) do
      {:ok, %{after: after_seq, limit: 500, patterns: patterns, opts: opts}}
    end
  end

  def join(_), do: {:error, :invalid_cursor}

  defp join_cursor(nil), do: {:ok, Export.status().head_seq}
  defp join_cursor(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp join_cursor(_), do: {:error, :invalid_cursor}
  defp join_topics(nil), do: {:ok, exported()}

  defp join_topics(topics) when is_list(topics) do
    if Enum.all?(topics, &is_binary/1), do: validate_patterns(topics, exported()), else: {:error, :topic_not_exported}
  end

  defp join_topics(_), do: {:error, :topic_not_exported}
  defp join_epoch(nil), do: {:ok, []}
  defp join_epoch(value), do: epoch(%{"epoch" => value})
  defp exported, do: Enum.map(Catalog.exported(), & &1.pattern)

  defp integer(params, key, default, min, max, code) do
    case Map.fetch(params, key) do
      :error -> {:ok, default}
      {:ok, value} -> parse_integer(value, min, max, code)
    end
  end

  defp parse_integer(value, min, max, code) when is_binary(value) do
    with true <- Regex.match?(~r/\A[0-9]+\z/, value),
         {number, ""} <- Integer.parse(value),
         true <- number >= min and (max == :infinity or number <= max) do
      {:ok, number}
    else
      _ -> {:error, code}
    end
  end

  defp parse_integer(_, _, _, code), do: {:error, code}

  defp epoch(%{"epoch" => epoch}) when is_binary(epoch), do: {:ok, [epoch: epoch]}
  defp epoch(%{"epoch" => _}), do: {:error, :invalid_cursor}
  defp epoch(_), do: {:ok, []}

  defp patterns(params) do
    exported = exported()

    case Map.fetch(params, "topics") do
      :error -> {:ok, exported}
      {:ok, value} when is_binary(value) -> validate_patterns(String.split(value, ","), exported)
      _ -> {:error, :topic_not_exported}
    end
  end

  defp validate_patterns(requested, exported) do
    if Enum.all?(requested, fn pattern ->
         valid_pattern?(pattern) and Enum.any?(exported, &narrowing?(String.split(pattern, "."), String.split(&1, ".")))
       end) do
      {:ok, requested}
    else
      {:error, :topic_not_exported}
    end
  end

  defp valid_pattern?(pattern) do
    Enum.all?(String.split(pattern, "."), &(&1 in ["*", "#"] or Regex.match?(~r/\A[^\s.*#]+\z/u, &1)))
  end

  # Deliberately conservative: keep segment positions and replace wildcards only with literals.
  defp narrowing?([], []), do: true
  defp narrowing?([same | requested], [same | exported]), do: narrowing?(requested, exported)

  defp narrowing?([literal | requested], [wildcard | exported]) when wildcard in ["*", "#"] and literal not in ["*", "#"],
    do: narrowing?(requested, exported)

  defp narrowing?(_, _), do: false
end
