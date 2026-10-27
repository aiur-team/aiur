defmodule Aiur.RecentMerge.CommitMessages do
  @moduledoc false

  @spec normalize([term()], (term() -> {:ok, String.t() | nil} | {:error, term()})) ::
          {:ok, [String.t()]} | {:error, term()}
  def normalize(messages, normalize_one) do
    messages
    |> Enum.take(100)
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case normalize_one.(message) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
