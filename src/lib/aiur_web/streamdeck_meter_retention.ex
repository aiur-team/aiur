defmodule AiurWeb.StreamdeckMeterRetention do
  @moduledoc "Orders account-wide poll readings independently of cached observation ages."

  alias Aiur.ProviderMeterSnapshot

  @spec newer?(ProviderMeterSnapshot.t(), map() | nil) :: boolean()
  def newer?(%ProviderMeterSnapshot{provider: :claude, source: :usage_api, summary_label: label} = snapshot, current) when is_binary(label) do
    case {snapshot.ingested_at, current && field(current, :summary_label), current && datetime(field(current, :ingested_at))} do
      {%DateTime{} = incoming, label, %DateTime{} = prior} when is_binary(label) -> DateTime.compare(incoming, prior) != :lt
      _ -> true
    end
  end

  def newer?(%ProviderMeterSnapshot{provider: :claude}, %{"summary_label" => label}) when is_binary(label), do: false
  def newer?(%ProviderMeterSnapshot{observed_at: nil}, _current), do: false
  def newer?(%ProviderMeterSnapshot{}, nil), do: true
  def newer?(%ProviderMeterSnapshot{}, %{"observed_at" => nil}), do: true

  def newer?(%ProviderMeterSnapshot{observed_at: observed_at}, %{"observed_at" => current_observed_at}) do
    case DateTime.from_iso8601(current_observed_at) do
      {:ok, current_observed_at, _offset} -> DateTime.compare(observed_at, current_observed_at) != :lt
      _ -> true
    end
  end

  def newer?(%ProviderMeterSnapshot{}, _current), do: true

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime(_value), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
