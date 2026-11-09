defmodule Aiur.HistoryCLI do
  @moduledoc """
  `aiur history export [--unsorted] [--after <n>] [--limit <k>] [--json]`:
  one page of past and open tickets from the local History store, for
  classification. Makes no GitHub reads; the page comes from
  `Aiur.BuildOrder.History.Export.page/1`.
  """

  alias Aiur.BuildOrder.History.Export
  alias Aiur.ControlCLI.Protocol
  alias Aiur.JSONSafe

  @untrusted_fields ["title", "labels", "body.excerpt"]

  @doc """
  Control-RPC entry point: runs the export and emits the launcher's exit and
  error markers, which are the only way a status or message reaches the caller.
  """
  @spec rpc(keyword()) :: :ok
  def rpc(opts) do
    Protocol.guarded("history export", fn -> opts |> run() |> Protocol.exit_marker() end)
  end

  @spec run(keyword()) :: 0 | 1
  def run(opts) do
    case build(opts) do
      {:ok, envelope} ->
        IO.puts(if Keyword.get(opts, :json, false), do: Jason.encode!(envelope), else: render(envelope))
        0

      {:error, reason} ->
        Protocol.control_error("aiur: history export: #{reason}")
        1
    end
  end

  @doc false
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    opts = Keyword.put(opts, :now, now)

    with {:ok, page} <- Export.page(Keyword.delete(opts, :json)) do
      {:ok,
       JSONSafe.normalize(%{
         schema_version: 1,
         page: "history-export",
         snapshot: %{captured_at: now},
         request: %{unsorted: Keyword.get(opts, :unsorted, false), after: Keyword.get(opts, :after, 0), limit: Keyword.get(opts, :limit, 200)},
         sources: page.sources,
         data: Map.take(page, [:tickets, :next_after, :matching_total, :unresolved_total]),
         auxiliary: %{untrusted_fields: @untrusted_fields, not_held: %{pr_files: "no Aiur store keeps pull-request file lists"}}
       })}
    end
  end

  @doc "Plain-text view of an export envelope; one line per ticket."
  @spec render(map()) :: String.t()
  def render(%{"request" => request, "sources" => sources, "data" => data}) do
    tickets = data["tickets"]
    filter = if request["unsorted"], do: " (unsorted)", else: ""
    next = if data["next_after"], do: "next --after #{data["next_after"]}", else: "last page"
    bodies = sources["issue_bodies"]

    header = [
      "history export: #{length(tickets)} of #{data["matching_total"]} matching#{filter}, #{next}",
      "sources: #{source("history", sources["history"])} · #{source("overrides", sources["epic_overrides"])} · " <>
        "#{source("features", sources["features"])} · bodies held #{bodies["held"]}/#{bodies["of"]} (#{bodies["retention_hours"]} h retention)",
      "unresolved (an input unknown): #{data["unresolved_total"]}"
    ]

    Enum.join(header ++ Enum.map(tickets, &row/1), "\n")
  end

  defp source(name, entry), do: "#{name} #{entry["freshness"]} (age #{age(entry["age_ms"])})"

  defp age(ms) when is_integer(ms) do
    seconds = div(ms, 1_000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
    end
  end

  defp age(_ms), do: "unknown"

  defp row(ticket) do
    epic = ticket["epic"]
    body = if Map.has_key?(ticket, "body"), do: "held", else: "unknown"
    title = if Map.has_key?(ticket, "title"), do: ticket["title"], else: "(title unknown)"

    "##{ticket["number"]}  #{Map.get(ticket, "state", "unknown")}  #{epic["key"]}/#{epic["source"]}  body: #{body}  pr #{pr(ticket)}  #{one_line(title)}"
  end

  defp pr(%{"pr_number" => nil}), do: "none"
  defp pr(%{"pr_number" => number}), do: "##{number}"
  defp pr(_ticket), do: "unknown"

  # The sanitiser keeps tabs and newlines; one ticket must stay one line.
  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
