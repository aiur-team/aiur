defmodule Aiur.Gateway.Status do
  @moduledoc """
  `aiur gateway list|status`: one row per registry entry.

  The launcher reads `agents --json` from every entry in parallel (it holds the tokens) and hands the
  raw results in as `:data`, a JSON list of `{name, status, output}`. This module adds the anonymous
  hello, derives connectivity and workload, and reads/writes `Aiur.Gateway.StatusCache`.

  Connectivity: `online` (hello and agents both answered), `offline` (transport failure; cache shown),
  `error` (answered but refused, invalid, or a different gateway id than the pin) and `unknown`
  (never reached, no cache). Cached values carry their age and never turn workload into `idle`/`0`.
  """

  import Aiur.ControlCLI.Protocol, only: [control_error: 1]

  alias Aiur.Gateway.{Discovery, Registry, StatusCache, Workload}

  # Launcher exit codes that mean "no answer" (69 unreachable, 124 timeout); any other failure is a refusal.
  @transport [69, 124]

  @spec run(keyword()) :: non_neg_integer()
  def run(opts) do
    with {:ok, view} <- or_error(Registry.get(), "gateway registry unavailable"),
         {:ok, results} <- or_error(Jason.decode(opts[:data] || "[]"), "launcher results are not JSON"),
         {:ok, targets} <- targets(view, opts[:peer]) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      get = Keyword.get(opts, :http_get, &Discovery.http_get/1)

      rows =
        targets
        |> Task.async_stream(&row(&1, results, get, now), max_concurrency: 8, timeout: 15_000, on_timeout: :kill_task, zip_input_on_exit: true)
        |> Enum.map(fn
          {:ok, row} -> row
          {:exit, {target, _reason}} -> build(target, :unreachable, StatusCache.read(target.name), now)
        end)

      print(rows, opts)
      0
    else
      {:error, {code, message}} ->
        control_error("aiur: " <> message)
        code
    end
  end

  defp or_error({:ok, _} = ok, _message), do: ok
  defp or_error({:error, reason}, message), do: {:error, {1, "#{message}: #{inspect(reason)}"}}

  defp targets(view, peer) do
    all =
      for {name, entry} <- view.instances, is_map(entry), is_binary(entry["url"]) do
        grants = with %{categories: categories} <- view.peers[to_string(name)], do: categories
        %{name: to_string(name), url: Discovery.hello_url(entry["url"]), pin: entry["gateway_id"], grants: grants}
      end
      |> Enum.sort_by(& &1.name)

    picked = if peer, do: Enum.filter(all, &(&1.name == peer)), else: all
    if peer && picked == [], do: {:error, {66, "no such gateway: #{peer}"}}, else: {:ok, picked}
  end

  defp row(target, results, get, now) do
    outcome =
      case {agents(results, target.name), get.(target.url)} do
        {:transport, _hello} -> :unreachable
        {{:ok, running}, {:ok, %{} = hello}} -> if target.pin && hello["gateway_id"] != target.pin, do: {:error, "pin mismatch"}, else: {:ok, running, hello}
        {{:ok, _running}, {:error, :hello_disabled}} -> {:error, "hello disabled"}
        {{:ok, _running}, {:error, :unrecognised}} -> {:error, "invalid hello"}
        {{:ok, _running}, _transport_failure} -> :unreachable
        {:refused, _hello} -> {:error, "refused"}
      end

    cached = StatusCache.read(target.name)

    with {:ok, running, hello} <- outcome do
      StatusCache.write(target.name, %{observed_at: DateTime.to_iso8601(now), agents: length(running), gateway_id: hello["gateway_id"], gateway_label: hello["gateway_label"], build: hello["build"]})
    end

    build(target, outcome, cached, now)
  end

  defp agents(results, name) do
    case Enum.find(results, &(&1["name"] == name)) do
      %{"status" => 0, "output" => output} -> parse_agents(output)
      %{"status" => status} when status in @transport -> :transport
      nil -> :transport
      _refused -> :refused
    end
  end

  defp parse_agents(output) do
    Enum.find_value(String.split(output || "", "\n"), :refused, fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"contract" => "aiur.agents", "running" => running}} when is_list(running) -> {:ok, running}
        _ -> nil
      end
    end)
  end

  defp build(target, {:ok, running, hello}, _cached, now) do
    finish(target, "online", nil, %{observed_at: now, agents: length(running), gateway_id: hello["gateway_id"]}, "fresh", now, nil)
  end

  defp build(target, outcome, cached, now) do
    {connectivity, reason} =
      case outcome do
        {:error, reason} -> {"error", reason}
        _ -> {if(cached == :none, do: "unknown", else: "offline"), nil}
      end

    case cached do
      {:ok, cache} -> finish(target, connectivity, reason, cache, "stale", now, Workload.derive("online", cache.agents))
      :none -> finish(target, connectivity, reason, nil, "none", now, nil)
    end
  end

  defp finish(target, connectivity, reason, data, freshness, now, last_workload) do
    %{
      gateway: target.name,
      registered: true,
      connectivity: connectivity,
      reason: reason,
      workload: Workload.derive(connectivity, data && data.agents),
      last_workload: last_workload,
      last_seen_at: data && DateTime.to_iso8601(data.observed_at),
      age_ms: data && max(DateTime.diff(now, data.observed_at, :millisecond), 0),
      freshness: freshness,
      gateway_id: (data && data.gateway_id) || target.pin,
      agents: data && data.agents,
      projects: nil,
      owned_tickets: nil,
      executor: nil,
      grants_to_peer: target.grants,
      grants_from_peer: nil
    }
  end

  defp print(rows, opts) do
    {sum, unknown} = totals(rows)

    cond do
      opts[:json] -> IO.puts(Jason.encode!(%{gateways: rows, totals: %{agents: sum, unknown: unknown}}))
      opts[:peer] -> Enum.each(fields(hd(rows)), fn {key, value} -> IO.puts("#{key}: #{value}") end)
      true -> print_table(rows, sum, unknown)
    end
  end

  defp print_table(rows, sum, unknown) do
    cached = rows |> Enum.filter(&(&1.freshness == "stale")) |> Enum.map(& &1.agents) |> Enum.sum()

    IO.puts("gateway\tregistered\tconnectivity\tworkload\tlast_seen\tgateway_id\tprojects\tagents\ttickets\texecutor\tgrants")
    Enum.each(rows, &IO.puts(Enum.map_join(fields(&1), "\t", fn {_key, value} -> value end)))
    IO.puts("agents total: #{sum}#{if cached > 0, do: " (#{cached} cached)"}#{if unknown > 0, do: " + unknown"}")
  end

  # Cached numbers count; only a gateway with no number at all makes the total "N + unknown".
  defp totals(rows), do: {rows |> Enum.map(&(&1.agents || 0)) |> Enum.sum(), Enum.count(rows, &is_nil(&1.agents))}

  defp fields(row) do
    age = age(row)

    [
      {"gateway", row.gateway},
      {"registered", if(row.registered, do: "yes", else: "no")},
      {"connectivity", row.connectivity <> if(row.reason, do: " (#{row.reason})", else: "")},
      {"workload", row.workload <> if(row.last_workload, do: " (last #{row.last_workload}, #{age})", else: "")},
      {"last_seen", age},
      {"gateway_id", (row.gateway_id && String.slice(row.gateway_id, 0, 8)) || "unknown"},
      {"projects", "unknown"},
      {"agents", if(row.agents, do: "#{row.agents}#{if row.freshness == "stale", do: " (#{age})"}", else: "unknown")},
      {"tickets", "unknown"},
      {"executor", "unknown"},
      {"grants", "to:#{list(row.grants_to_peer)} from:unknown"}
    ]
  end

  defp list(nil), do: "unknown"
  defp list(categories), do: Enum.join(categories, ",")

  defp age(%{freshness: "none"}), do: "never"
  defp age(%{freshness: "fresh"}), do: "now"

  defp age(%{age_ms: ms}) do
    s = div(ms, 1000)

    cond do
      s < 60 -> "#{s}s ago"
      s < 3600 -> "#{div(s, 60)}m ago"
      s < 86_400 -> "#{div(s, 3600)}h ago"
      true -> "#{div(s, 86_400)}d ago"
    end
  end
end
