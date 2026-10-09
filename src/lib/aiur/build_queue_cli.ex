defmodule Aiur.BuildQueueCLI do
  @moduledoc "Human and JSON views of the version 1 build queue read model."
  alias Aiur.BuildOrder.ProgressRenderer
  alias Aiur.{BuildQueue, JSONSafe}
  alias Aiur.BuildQueue.MutationCLI

  @spec run(keyword()) :: 0 | 1 | 64 | 124
  def run(opts \\ [])

  def run(opts) do
    if Keyword.get(opts, :verb, :show) == :show, do: show(opts), else: MutationCLI.run(opts)
  end

  defp show(opts) do
    with :ok <- validate(opts),
         envelope <- BuildQueue.show(Keyword.get(opts, :server, Aiur.BuildQueue.Server)),
         {:ok, envelope} <- select(envelope, Keyword.get(opts, :queue)) do
      envelope = JSONSafe.normalize(envelope)
      if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(envelope)), else: human(envelope)
      if envelope["status"] in ["running", "writes_paused"], do: 0, else: 1
    else
      {:error, reason} ->
        Keyword.get(opts, :error_fun, &default_error/1).("aiur: queue show #{reason}")
        1
    end
  end

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

  defp human(envelope) do
    IO.puts("build queue  #{envelope["status"]}  captured #{envelope["snapshot"]["captured_at"]}")
    envelope["sources"] |> Enum.sort() |> Enum.each(fn {name, source} -> IO.puts("#{name}  observed #{source["observed_at"] || "unknown"}  #{freshness(source)}#{reasons(source)}") end)
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
    IO.puts("  pos  ticket  state  waiting on  rank")

    Enum.each(queue["items"], fn item ->
      IO.puts("  #{item["position"] || "—"}  ##{item["number"]}  #{item["state"]}  #{waiting(item["prerequisites"])}  #{rank(item)}#{attention(item)}")
    end)
  end

  defp progress(progress) do
    completion = %{progress: progress["percent"], progress_resolution: progress["resolution"], progress_resolved_count: progress["resolved"], member_count: progress["total"]}
    rendered = ProgressRenderer.terminal(completion)
    if is_number(progress["percent"]), do: "#{rendered} (completed #{progress["completed"] || "unknown"}/#{progress["total"] || "unknown"})", else: rendered
  end

  defp waiting(prerequisites) do
    case Enum.reject(prerequisites, &(&1["verdict"] == "satisfied")) do
      [] -> "—"
      edges -> Enum.map_join(edges, ", ", &"##{&1["number"]} #{&1["verdict"]} (#{&1["source"]})")
    end
  end

  defp rank(%{"downstream_open" => count, "rank" => [_, priority | _]}) when is_integer(count), do: "#{count} downstream · p#{priority}"
  defp rank(_item), do: "unknown"
  defp attention(%{"attention" => nil}), do: ""
  defp attention(item), do: "  attention #{inspect(item["attention"])}"
end
