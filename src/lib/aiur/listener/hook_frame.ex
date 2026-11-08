defmodule Aiur.Listener.HookFrame do
  @moduledoc false

  @max_entries 50
  @max_bytes 64 * 1024

  @doc "Bound rendered entries, preserving metadata while truncating only the first body's UTF-8 bytes."
  @spec render(Enumerable.t(), (list(String.t()) -> String.t()), keyword()) :: {:ok, String.t(), non_neg_integer()} | :none | {:error, :frame_metadata_too_large}
  def render(entries, wrap, opts \\ []) do
    budget = Keyword.get(opts, :budget, @max_bytes)
    marker = Keyword.get(opts, :suffix, " …[truncated]")

    entries
    |> Enum.take(@max_entries)
    |> Enum.reduce_while([], fn entry, lines ->
      line = entry.prefix <> entry.body <> entry.suffix

      cond do
        byte_size(wrap.(lines ++ [line])) <= budget -> {:cont, lines ++ [line]}
        lines != [] -> {:halt, lines}
        true -> {:halt, truncate(entry, wrap, marker, budget)}
      end
    end)
    |> finish(wrap)
  end

  defp truncate(entry, wrap, marker, budget) do
    available = budget - byte_size(wrap.([entry.prefix <> marker <> entry.suffix]))

    if available < 0 do
      {:error, :frame_metadata_too_large}
    else
      body = binary_part(entry.body, 0, min(available, byte_size(entry.body)))
      [entry.prefix <> valid_prefix(body) <> marker <> entry.suffix]
    end
  end

  defp valid_prefix(body) do
    if String.valid?(body), do: body, else: valid_prefix(binary_part(body, 0, byte_size(body) - 1))
  end

  defp finish({:error, _} = error, _wrap), do: error
  defp finish([], _wrap), do: :none
  defp finish(lines, wrap), do: {:ok, wrap.(lines), length(lines)}
end
