defmodule Aiur.Usage do
  @moduledoc "Shared, identity-safe read model for provider and ticket usage."

  alias Aiur.JSONSafe

  @providers %{
    claude: Aiur.Usage.Provider.Claude,
    codex: Aiur.Usage.Provider.Codex,
    github: Aiur.Usage.Provider.GitHub,
    broker: Aiur.Usage.Provider.Broker,
    ticket: Aiur.Usage.Provider.Ticket
  }

  @doc "Provider names served by this release. Add a provider adapter here."
  @spec providers() :: [atom()]
  def providers, do: Map.keys(@providers) |> Enum.sort()

  @doc "Read every registered provider through the same envelope."
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    Enum.map(@providers, fn {provider, module} -> {provider, normalize(module.read(opts))} end)
    |> Map.new()
  end

  @doc "Read one registered provider, returning `{:error, :unknown_provider}` otherwise."
  @spec provider(binary(), keyword()) :: {:ok, map()} | {:error, :unknown_provider}
  def provider(name, opts \\ [])

  def provider(name, opts) when is_binary(name) do
    case Enum.find(@providers, fn {key, _} -> Atom.to_string(key) == name end) do
      {_key, module} -> {:ok, module.read(opts) |> normalize()}
      nil -> {:error, :unknown_provider}
    end
  end

  def provider(_name, _opts), do: {:error, :unknown_provider}

  @doc "Build the shared record consumed by the dashboard's provider usage cards."
  @spec dashboard_card(map()) :: {:ok, struct()} | :error
  def dashboard_card(%{provider: provider} = card) when is_atom(provider) do
    if Map.has_key?(@providers, provider) do
      observed_at = parse_datetime(Map.get(card, :observed_at))

      health =
        case Map.get(card, :health) do
          value when is_map(value) -> value
          _ -> %{}
        end

      freshness =
        case Map.get(card, :freshness) do
          %{status: status} -> status
          _ -> :unknown
        end

      age_ms = if is_integer(Map.get(health, :age_seconds)), do: health.age_seconds * 1_000, else: age_ms(observed_at)

      record = %{
        provider: provider,
        observed_at: observed_at,
        age_ms: age_ms,
        freshness: freshness,
        source: "provider_meter_projection",
        fields: %{windows: Map.get(card, :windows, %{}), health: health}
      }

      {:ok, struct(Map.fetch!(@providers, provider), record)}
    else
      :error
    end
  end

  def dashboard_card(_card), do: :error

  @spec json_snapshot(keyword()) :: map()
  def json_snapshot(opts \\ []), do: JSONSafe.normalize(%{contract: "aiur.usage", contract_version: 1, providers: snapshot(opts)})

  defp normalize(%{provider: provider} = record), do: record |> Map.put_new(:age_ms, age_ms(Map.get(record, :observed_at))) |> Map.put_new(:source, Atom.to_string(provider)) |> JSONSafe.normalize()
  defp age_ms(%DateTime{} = date), do: max(DateTime.diff(DateTime.utc_now(), date, :millisecond), 0)
  defp age_ms(_), do: nil

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> date
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
