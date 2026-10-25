defmodule Aiur.Usage.CLI do
  @moduledoc false
  alias Aiur.AccountsCLI
  alias Aiur.Accounts.UsageReadings
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @spec rpc(binary() | nil, boolean()) :: :ok
  def rpc(provider \\ nil, json \\ false) do
    guarded("usage", fn ->
      result = run(provider, json)
      exit_marker(result)
    end)
  end

  @doc false
  @spec legacy_accounts(boolean(), String.t() | nil) :: :ok
  def legacy_accounts(json, harness) do
    guarded("accounts", fn ->
      AccountsCLI.accounts(json, harness, &UsageReadings.snapshot("claude", &1))
      exit_marker(0)
    end)
  end

  @doc false
  @spec legacy_ticket_usage(String.t(), boolean()) :: :ok
  def legacy_ticket_usage(identifier, json) do
    guarded("ticket-usage", fn ->
      result = Aiur.TicketUsageCLI.run(identifier, json: json)
      exit_marker(result)
    end)
  end

  @spec run(binary() | nil, boolean(), keyword()) :: 0 | 64
  def run(provider \\ nil, json \\ false, opts \\ []) do
    case payload(provider, opts) do
      {:ok, payload} ->
        IO.puts(if json, do: Jason.encode!(payload), else: render(payload, provider))
        0

      {:error, :unknown_provider} ->
        IO.puts(:stderr, "aiur: usage provider must be one of #{Enum.join(Aiur.Usage.providers(), ", ")}")
        64
    end
  end

  def payload(provider, opts \\ [])
  @spec payload(binary() | nil, keyword()) :: {:ok, map()} | {:error, :unknown_provider}
  def payload(nil, opts), do: {:ok, Aiur.Usage.json_snapshot(opts)}

  def payload(provider, opts) do
    with {:ok, item} <- Aiur.Usage.provider(provider, opts), do: {:ok, Aiur.JSONSafe.normalize(%{contract: "aiur.usage", contract_version: 1, provider: item})}
  end

  @spec render(map(), binary() | nil) :: String.t()
  def render(%{"providers" => snapshot}, nil) do
    header = ["PROVIDER  FRESHNESS  AGE       SOURCE"]
    rows = Enum.map(Aiur.Usage.providers(), fn provider -> row(provider, Map.fetch!(snapshot, Atom.to_string(provider))) end)
    Enum.join(header ++ rows, "\n")
  end

  def render(payload, provider) do
    item = payload["provider"]
    header = "#{provider}  #{item["freshness"] || "unknown"}  #{age(item["age_ms"])}  #{item["source"] || "unknown"}"
    details = item["fields"] |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("\n", fn {key, value} -> "  #{key}: #{inspect(value)}" end)
    if details == "", do: header, else: header <> "\n" <> details
  end

  defp row(provider, record), do: "#{String.pad_trailing(to_string(provider), 8)}  #{String.pad_trailing(to_string(record["freshness"]), 10)}  #{age(record["age_ms"])}  #{record["source"]}"
  defp age(age) when is_integer(age), do: "#{age}ms"
  defp age(_), do: "unknown"
end
