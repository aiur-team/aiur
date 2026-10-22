defmodule Aiur.TicketUsageCLI do
  @moduledoc """
  `aiur ticket-usage <ticket> [--json]` — one ticket's model usage per session,
  model and provider. `--json` prints the same versioned payload as
  `GET /api/v1/:issue_identifier/usage`.
  """

  alias AiurWeb.Api.Usage.TicketUsage

  @messages %{
    invalid_identifier: "expects a GitHub issue number",
    usage_not_found: "found no usage recorded for ticket",
    usage_unavailable: "could not read the usage ledger"
  }

  @spec run(String.t(), keyword()) :: 0 | 1
  def run(identifier, opts \\ []) do
    case TicketUsage.fetch(identifier, Keyword.get(opts, :usage_opts, [])) do
      {:ok, payload} ->
        IO.puts(if Keyword.get(opts, :json, false), do: Jason.encode!(payload), else: render(payload))
        0

      {:error, reason} ->
        IO.puts(:stderr, "aiur: ticket-usage #{Map.fetch!(@messages, reason)} #{identifier}")
        1
    end
  end

  @doc "Plain-text view of a usage payload."
  @spec render(map()) :: String.t()
  def render(payload) do
    ticket = payload["ticket"]

    header = [
      "Usage — #{ticket["owner"]}/#{ticket["repository"]}##{ticket["identifier"]} (#{payload["state"]}, #{payload["currency"]})",
      "Total     #{measure(payload["totals"])}"
    ]

    sessions =
      Enum.flat_map(payload["sessions"], fn session ->
        ["", "Session #{session["run_id"] || "unknown"}  #{measure(session)}"] ++
          Enum.map(session["by_model"], &"  model     #{pad(&1["model"])} #{measure(&1)}") ++
          Enum.map(session["by_provider"], &"  provider  #{pad(provider(&1))} #{measure(&1)}")
      end)

    Enum.join(header ++ sessions, "\n")
  end

  defp measure(entry) do
    tokens = entry["tokens"] |> Enum.sort() |> Enum.map_join(" ", fn {dimension, count} -> "#{dimension}=#{count}" end)
    "#{cost(entry["api_equivalent"]["amount"])}  #{if tokens == "", do: "no tokens", else: tokens}"
  end

  defp cost(%{"USD" => amount}), do: "$#{amount}"
  defp cost(_amount), do: "$n/a"

  defp provider(%{"provider" => provider, "upstream_provider" => upstream}) when is_binary(upstream), do: "#{provider} -> #{upstream}"
  defp provider(%{"provider" => provider}), do: to_string(provider)

  defp pad(value), do: String.pad_trailing(to_string(value || "unknown"), 24)
end
