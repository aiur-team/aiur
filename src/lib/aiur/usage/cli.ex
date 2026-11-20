defmodule Aiur.Usage.CLI do
  @moduledoc false
  alias Aiur.Accounts.UsageReadings
  alias Aiur.AccountsCLI
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
      AccountsCLI.accounts(json, harness, &UsageReadings.snapshot_for_accounts/1)
      exit_marker(0)
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
    Enum.join(header ++ rows ++ UsageReadings.failure_lines(), "\n")
  end

  def render(payload, provider) do
    item = payload["provider"]
    header = "#{provider}  #{item["freshness"] || "unknown"}  #{age(item["age_ms"])}  #{item["source"] || "unknown"}"
    details = item["fields"] |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("\n", fn {key, value} -> "  #{key}: #{inspect(value)}" end)
    details = if provider == "netlify", do: netlify_summary(item["fields"]) <> if(details == "", do: "", else: "\n" <> details), else: details
    details = if provider == "openrouter", do: openrouter_summary(item["fields"]), else: details
    if details == "", do: header, else: header <> "\n" <> details
  end

  # OpenRouter's reading is two facts a reader wants line by line: what is left
  # on the key, and what each route has spent. The generic field dump would
  # print both as nested maps.
  defp openrouter_summary(fields) do
    [credit_line(Map.get(fields, "credits")) | route_lines(Map.get(fields, "routes"))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp credit_line(%{} = credits) do
    remaining = number(Map.get(credits, "remaining"))
    limit = number(Map.get(credits, "limit"))
    used = number(Map.get(credits, "used_percent"))

    text =
      cond do
        is_nil(remaining) and is_nil(limit) -> "no reading"
        is_nil(limit) -> money(remaining) <> " remaining"
        is_nil(remaining) -> money(limit) <> " limit"
        true -> money(remaining) <> " remaining of " <> money(limit) <> " limit"
      end

    "  credits: " <> if(is_number(used), do: "#{text} (#{used}% used)", else: text)
  end

  defp credit_line(_absent), do: "  credits: no reading"

  defp route_lines(routes) when is_list(routes) and routes != [] do
    Enum.flat_map(routes, &route_line/1)
  end

  defp route_lines(_absent), do: ["  routes: none configured"]

  defp route_line(%{} = route) do
    head = "  route: #{Map.get(route, "route")}"

    case Map.get(route, "readings") do
      [] ->
        [head <> "  no reading"]

      readings when is_list(readings) ->
        Enum.map(readings, fn reading -> head <> "  " <> spend_line(reading) end)
    end
  end

  defp route_line(_absent), do: []

  defp spend_line(%{} = reading) do
    via = Map.get(reading, "upstream")
    amount = money(Map.get(reading, "amount"))
    basis = Map.get(reading, "basis")
    label = if is_binary(via), do: "via #{via}", else: "upstream unknown"
    "#{label} #{amount} #{Map.get(reading, "currency")} (#{basis})"
  end

  defp money(value) when is_number(value), do: "$" <> to_string(value)
  defp money(value) when is_binary(value), do: "$" <> value
  defp money(_value), do: "unknown"

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp netlify_summary(fields) do
    credits = Map.get(fields, "credits", %{})
    remaining = Map.get(credits, "estimated_remaining")

    case remaining do
      value when is_number(value) -> "  estimated credits: #{Float.round(value * 1.0, 1)}"
      _ -> "  estimated credits: unavailable"
    end
  end

  defp row(provider, record), do: "#{String.pad_trailing(to_string(provider), 8)}  #{String.pad_trailing(to_string(record["freshness"]), 10)}  #{age(record["age_ms"])}  #{record["source"]}"
  defp age(age) when is_integer(age), do: "#{age}ms"
  defp age(_), do: "unknown"
end
