defmodule AiurWeb.ConversationApiParams do
  @moduledoc false
  @cursors ~w(tail before after around from_start)a

  @spec entries(map()) :: {:ok, keyword()} | {:error, atom()}
  def entries(params) do
    with {:ok, opts} <- numbers(params, @cursors, :invalid_cursor),
         {:ok, limit} <- numbers(params, [:limit], :invalid_limit),
         {:ok, kinds} <- kinds(params) do
      {:ok, opts ++ limit ++ kinds}
    end
  end

  @spec anchors(map()) :: {:ok, keyword()} | {:error, atom()}
  def anchors(params) do
    with {:ok, range} <- numbers(params, [:pos_from, :pos_to], :invalid_range),
         {:ok, kinds} <- kinds(params) do
      first = Keyword.get(range, :pos_from, 0)
      last = Keyword.get(range, :pos_to, 9_223_372_036_854_775_807)

      cond do
        range == [] -> {:ok, kinds}
        first <= last -> {:ok, kinds ++ [pos_range: {first, last}]}
        true -> {:error, :invalid_range}
      end
    end
  end

  @spec subject(map()) :: {:ok, :executor | {String.t(), String.t(), String.t()}} | {:error, :invalid_subject}
  def subject(%{"subject" => "executor"}), do: {:ok, :executor}

  def subject(%{"subject" => "worker", "owner" => owner, "repository" => repository, "identifier" => identifier})
      when is_binary(owner) and owner != "" and is_binary(repository) and repository != "" and is_binary(identifier) and identifier != "",
      do: {:ok, {owner, repository, identifier}}

  def subject(_params), do: {:error, :invalid_subject}

  defp numbers(params, keys, error) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, opts} ->
      case Map.fetch(params, Atom.to_string(key)) do
        :error -> {:cont, {:ok, opts}}
        {:ok, "true"} when key in [:tail, :from_start] -> {:cont, {:ok, [{key, true} | opts]}}
        {:ok, value} -> parse_number(value, key, opts, error)
      end
    end)
  end

  defp parse_number(value, key, opts, error) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:cont, {:ok, [{key, number} | opts]}}
      _ -> {:halt, {:error, error}}
    end
  end

  defp parse_number(_value, _key, _opts, error), do: {:halt, {:error, error}}

  defp kinds(params) do
    case Map.fetch(params, "kinds") do
      :error -> {:ok, []}
      {:ok, value} when is_binary(value) -> {:ok, [kinds: String.split(value, ",", trim: true)]}
      _ -> {:error, :invalid_kinds}
    end
  end
end
