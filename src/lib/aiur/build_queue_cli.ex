defmodule Aiur.BuildQueueCLI do
  @moduledoc "Human and JSON views of the version 1 build queue read model."
  alias Aiur.BuildOrder.ProgressRenderer
  alias Aiur.{BuildQueue, JSONSafe}
  alias Aiur.BuildQueue.{ClaimProbe, MutationCLI, SetSummary}

  @spec run(keyword()) :: 0 | 1 | 64 | 124
  def run(opts \\ [])

  def run(opts) do
    case Keyword.get(opts, :verb, :show) do
      :show -> show(opts)
      :order -> if is_nil(opts[:queue]) and is_nil(opts[:to]), do: show(Keyword.put(opts, :order_only, true)), else: MutationCLI.run(opts)
      _ -> MutationCLI.run(opts)
    end
  end

  defp show(opts) do
    with :ok <- validate(opts),
         envelope <- BuildQueue.show(Keyword.get(opts, :server, Aiur.BuildQueue.Server)),
         {:ok, envelope} <- select(envelope, Keyword.get(opts, :queue)) do
      envelope = envelope |> select_next(opts) |> JSONSafe.normalize()
      if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(envelope)), else: human(envelope, opts)
      if envelope["status"] in ["running", "writes_paused"], do: 0, else: 1
    else
      {:error, reason} ->
        Keyword.get(opts, :error_fun, &default_error/1).("aiur: queue show #{reason}")
        1
    end
  end

  # Sample dispatch after the queue RPC: orchestrator callers of the read model must not call themselves.
  defp select_next(%{queues: [_ | _] = queues} = envelope, opts) do
    if Enum.all?(queues, &(is_integer(Map.get(&1, :set_rank)) and Map.has_key?(&1, :counts))) do
      SetSummary.select_next(envelope, ClaimProbe.next_set(Keyword.get(opts, :claim_probe, ClaimProbe.impl())))
    else
      envelope
    end
  end

  defp select_next(envelope, _opts), do: envelope

  defp default_error(message), do: IO.puts(:stderr, message)

  defp validate(opts) do
    if Keyword.get(opts, :queue) in [nil] or (is_binary(opts[:queue]) and opts[:queue] != ""), do: :ok, else: {:error, "expects a non-empty queue name"}
  end

  defp select(envelope, nil), do: {:ok, envelope}

  defp select(%{status: status} = envelope, _name) when status not in [:running, :writes_paused], do: {:ok, envelope}

  defp select(envelope, name) do
    case Enum.filter(envelope.queues, &(&1.name == name)) do
      [] -> {:error, "could not find queue #{inspect(name)}"}
      queues -> {:ok, %{envelope | queues: queues}}
    end
  end

  defp human(envelope, opts) do
    if opts[:order_only] do
      Enum.each(envelope["queues"], &IO.puts("#{&1["set_rank"] || "unknown"}  #{&1["name"]}"))
    else
      print_model(envelope)
    end
  end

  defp print_model(envelope) do
    IO.puts("build queue  #{envelope["status"]}  captured #{envelope["snapshot"]["captured_at"]}")
    envelope["sources"] |> Enum.sort() |> Enum.each(fn {name, source} -> IO.puts("#{name}  observed #{source["observed_at"] || "unknown"}  #{freshness(source)}#{reasons(source)}") end)
    next = Enum.find(envelope["queues"], &(is_integer(&1["set_rank"]) and &1["next"] == true))
    if next, do: IO.puts("NEXT  #{next["name"]}  rank #{next["set_rank"]}")
    Enum.each(envelope["queues"], &print_queue/1)
  end

  defp freshness(%{"freshness" => freshness, "age_ms" => age}) when is_integer(age), do: "#{freshness} (#{age(age)} ago)"
  defp freshness(%{"freshness" => "unknown"}), do: "unknown"
  defp freshness(%{"freshness" => freshness}), do: "#{freshness} (age unknown)"
  defp age(ms) when ms >= 60_000, do: "#{div(ms, 60_000)}m"
  defp age(ms), do: "#{div(ms, 1000)}s"
  defp reasons(%{"reasons" => []}), do: ""
  defp reasons(source), do: "  reasons #{inspect(source["reasons"])}"

  defp print_queue(queue) do
    IO.puts("#{queue["name"]}  #{progress(queue["progress"])}#{if queue["held"], do: "  held", else: ""}")

    print_summary(queue)
    if queue["start_trigger"], do: IO.puts("  start on #{queue["start_trigger"]}#{if queue["start_trigger_source"] == "config", do: " (default)", else: ""}")
    IO.puts("  pos  ticket  state  waiting on  rank")

    Enum.each(queue["items"], fn item ->
      IO.puts("  #{item["position"] || "—"}  ##{item["number"]}  #{item["state"]}  #{item_waiting(item)}  #{rank(item)}#{attention(item)}")
    end)
  end

  defp print_summary(queue) do
    if is_integer(queue["set_rank"]) and queue["counts"] do
      counts = queue["counts"]

      IO.puts(
        "  set rank #{queue["set_rank"]}  #{queue["state"]}  held #{queue["held"]}  ready #{counts["ready"] || "unknown"} / started #{counts["started"] || "unknown"} / done #{counts["done"] || "unknown"}#{if queue["waiting_reason"], do: "  #{queue["waiting_reason"]}"}"
      )
    end
  end

  defp progress(progress) do
    completion = %{progress: progress["percent"], progress_resolution: progress["resolution"], progress_resolved_count: progress["resolved"], member_count: progress["total"]}
    rendered = ProgressRenderer.terminal(completion)
    if is_number(progress["percent"]), do: "#{rendered} (completed #{progress["completed"] || "unknown"}/#{progress["total"] || "unknown"})", else: rendered
  end

  defp item_waiting(%{"reason" => "queue_set_order:" <> _ = reason}), do: reason
  defp item_waiting(item), do: waiting(item["prerequisites"])

  defp waiting(prerequisites) do
    case Enum.reject(prerequisites, &(&1["verdict"] == "satisfied" and &1["optimistic"] != true)) do
      [] -> "—"
      edges -> Enum.map_join(edges, ", ", &(&1["description"] || "##{&1["number"]} #{&1["verdict"]} (#{&1["source"]})"))
    end
  end

  defp rank(%{"downstream_open" => count, "rank" => [_, priority | _]}) when is_integer(count), do: "#{count} downstream · p#{priority}"
  defp rank(_item), do: "unknown"
  defp attention(%{"attention" => nil}), do: ""
  defp attention(item), do: "  attention #{inspect(item["attention"])}"
end
