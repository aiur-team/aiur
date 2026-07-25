defmodule Aiur.DecisionQuery.Cursor do
  @moduledoc false

  alias Aiur.DecisionQuery.Params

  @maximum_bytes 1_024

  @type t :: %{created_at: DateTime.t(), decision_id: String.t()}

  @spec parse(term()) :: {:ok, t() | nil} | {:error, {:cursor, :invalid}}
  def parse(nil), do: {:ok, nil}

  def parse(%{created_at: %DateTime{} = created_at, decision_id: decision_id}) do
    case Params.normalize_decision_id(decision_id) do
      {:ok, normalized_id} -> {:ok, %{created_at: created_at, decision_id: normalized_id}}
      _invalid -> {:error, {:cursor, :invalid}}
    end
  end

  def parse(cursor) when is_binary(cursor) and byte_size(cursor) <= @maximum_bytes do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"created_at" => created_at, "decision_id" => decision_id}} <- Jason.decode(decoded),
         {:ok, datetime} <- parse_datetime(created_at),
         {:ok, normalized_id} <- Params.normalize_decision_id(decision_id) do
      {:ok, %{created_at: datetime, decision_id: normalized_id}}
    else
      _invalid -> {:error, {:cursor, :invalid}}
    end
  end

  def parse(_cursor), do: {:error, {:cursor, :invalid}}

  @spec encode(t()) :: String.t()
  def encode(%{created_at: %DateTime{} = created_at, decision_id: decision_id}) when is_binary(decision_id) do
    %{"created_at" => DateTime.to_iso8601(created_at), "decision_id" => decision_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, :invalid}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid}
end
