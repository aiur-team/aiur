defmodule Aiur.ExperimentsCLI do
  @moduledoc "Experiments commands for the local control RPC."
  alias Aiur.{Experiments, JSONSafe}

  @switches [
    status: :string,
    kind: :string,
    json: :boolean,
    refresh: :boolean,
    spec_json: :string,
    draft: :boolean,
    no_freeze: :boolean,
    title: :string,
    line: :string,
    metric: :keep,
    hypothesis: :string,
    window: :string,
    reason: :string
  ]
  @allowed %{
    events: [:json, :refresh],
    freeze: [:window, :reason, :json],
    metrics: [:json],
    list: [:status, :kind, :json],
    show: [:json],
    create: [:spec_json, :draft, :no_freeze, :json, :title, :line, :metric, :hypothesis]
  }

  @spec run(keyword()) :: 0 | 1 | 64
  def run(opts \\ []) do
    verb = Keyword.get(opts, :verb)
    {flags, positional, invalid} = OptionParser.parse(Keyword.get(opts, :argv, []), strict: @switches)

    if invalid == [] and Map.has_key?(@allowed, verb) and Enum.all?(Keyword.keys(flags), &(&1 in @allowed[verb])) do
      dispatch(verb, Keyword.put(flags, :error_fun, Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1))), positional)
    else
      usage(opts)
    end
  end

  defp dispatch(:list, flags, []) do
    filters = Keyword.take(flags, [:status, :kind])

    if flags[:status] in [nil, "draft", "active", "concluded", "abandoned", "report_due", "reported", "cancelled"] and flags[:kind] in [nil, "before_after", "ab"],
      do: result(Experiments.list(filters), flags, :list),
      else: usage(flags)
  end

  defp dispatch(:metrics, flags, []), do: result({:ok, Experiments.metric_catalog()}, flags, :metrics)

  defp dispatch(:events, flags, [id]) do
    case Experiments.events(id, Keyword.take(flags, [:refresh])) do
      {:ok, snapshot} ->
        if snapshot["incomplete_sources"] != [], do: flags[:error_fun].("warning: incomplete event sources: " <> Enum.join(snapshot["incomplete_sources"], ", "))
        result({:ok, snapshot}, flags, :events)

      error ->
        result(error, flags, {:show, id})
    end
  end

  defp dispatch(:show, flags, [id]) do
    case Experiments.fetch(id) do
      {:ok, data} -> result({:ok, Map.put(data, :pack_problems, Experiments.metric_catalog().problems)}, flags, {:show, id})
      error -> result(error, flags, {:show, id})
    end
  end

  defp dispatch(:freeze, flags, [id]) do
    case Experiments.freeze(id, flags[:window], Keyword.take(flags, [:reason])) do
      {:error, :invalid_window} -> usage(flags)
      response -> result(response, flags, :freeze)
    end
  end

  defp dispatch(:create, flags, []) do
    case attributes(flags) do
      {:ok, attrs} ->
        attrs = if flags[:draft], do: Map.put(attrs, "status", "draft"), else: attrs
        result(Experiments.create(attrs, origin: %{kind: "manual", ref: "cli"}, freeze: !flags[:no_freeze]), flags, :create)

      {:usage, _reason} ->
        usage(flags)

      {:error, reason} ->
        result({:error, reason}, flags, :create)
    end
  end

  defp dispatch(_verb, flags, _positional), do: usage(flags)

  defp attributes(flags) do
    case flags[:spec_json] do
      nil ->
        quick_attributes(flags)

      json ->
        if Enum.any?([:title, :line, :metric, :hypothesis], &Keyword.has_key?(flags, &1)) do
          {:usage, :mixed_forms}
        else
          decode_attributes(json)
        end
    end
  end

  defp decode_attributes(json) do
    case Jason.decode(json) do
      {:ok, %{} = attrs} -> {:ok, attrs}
      _ -> {:error, [%{path: "spec", message: "expected a JSON object"}]}
    end
  end

  defp quick_attributes(flags) do
    with title when is_binary(title) and title != "" <- flags[:title],
         line when is_binary(line) <- flags[:line],
         [type, ref] <- String.split(line, ":", parts: 2),
         true <- type != "" and ref != "",
         metrics when metrics != [] <- Keyword.get_values(flags, :metric) do
      [ref | time] = String.split(ref, "@", parts: 2)
      change = %{"type" => type, "ref" => ref, "time" => List.first(time)}

      {:ok,
       %{
         "title" => title,
         "hypothesis" => flags[:hypothesis] || "",
         "design" => %{"kind" => "before_after", "change" => change},
         "metrics" => Enum.map(metrics, &metric_attributes/1)
       }}
    else
      _ -> {:usage, :quick_form}
    end
  end

  defp metric_attributes(metric) do
    [ref | direction] = String.split(metric, ":", parts: 2)
    %{"ref" => ref, "direction" => List.first(direction) || "decrease"}
  end

  defp result({:ok, spec}, flags, :create) do
    case Experiments.fetch(spec.id) do
      {:ok, detail} ->
        snapshot = detail.snapshots |> Enum.filter(&(&1["window_name"] == "before")) |> Enum.max_by(& &1["revision"], fn -> nil end)
        data = JSONSafe.normalize(spec)
        data = if snapshot && !flags[:no_freeze], do: Map.put(data, "frozen_snapshot", snapshot), else: data
        if flags[:json], do: IO.puts(Jason.encode!(data)), else: print_human(data, :create)
        0

      error ->
        result(error, flags, :create)
    end
  end

  defp result({:ok, data}, flags, verb) do
    normalized = JSONSafe.normalize(data)
    if flags[:json], do: IO.puts(Jason.encode!(normalized)), else: print_human(normalized, verb)
    0
  end

  defp result({:error, :not_found}, flags, {:show, id}) do
    flags[:error_fun].("no experiment #{id}")
    1
  end

  defp result({:error, errors}, flags, _verb) do
    errors |> List.wrap() |> Enum.each(&print_error(&1, flags[:error_fun]))
    1
  end

  defp print_error(%{path: path, message: message}, error_fun), do: error_fun.("#{path}: #{message}")
  defp print_error({:reason_required, revision}, error_fun), do: error_fun.("snapshot revision r#{revision} already exists; --reason is required to re-freeze")
  defp print_error({path, message}, error_fun) when is_binary(path) and is_binary(message), do: error_fun.("#{path}: #{message}")
  defp print_error(reason, error_fun), do: error_fun.("aiur: experiments #{inspect(reason)}")

  defp print_human(rows, :list) do
    Enum.each(rows, fn row -> IO.puts("#{row["id"]}  #{row["status"] || "unreadable"}  #{row["kind"]}  #{row["title"]}") end)
  end

  defp print_human(data, :create) do
    IO.puts(Jason.encode!(Map.delete(data, "frozen_snapshot"), pretty: true))
    if data["frozen_snapshot"], do: print_snapshot(data["frozen_snapshot"])
  end

  defp print_human(data, :freeze), do: print_snapshot(data)

  defp print_human(data, {:show, _id}) do
    IO.puts(Jason.encode!(data, pretty: true))
    Enum.each(data["snapshots"], &print_snapshot/1)
  end

  defp print_human(data, _verb), do: IO.puts(Jason.encode!(data, pretty: true))

  defp print_snapshot(snapshot) do
    window = snapshot["window"]
    coverage = snapshot["metrics"] |> Enum.sort() |> Enum.map_join(", ", fn {ref, metric} -> "#{ref}=#{Jason.encode!(metric["coverage"])} (n=#{metric["summary"]["n"]})" end)

    IO.puts(
      "froze #{snapshot["window_name"]} window #{window["start"]}..#{window["end"]}: #{snapshot["observation_count"]} observations, coverage #{coverage}; r#{snapshot["revision"]} sha #{String.slice(snapshot["sha256"], 0, 12)}"
    )
  end

  defp usage(opts) do
    error_fun = Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1))

    error_fun.(
      "aiur: experiments expects list [--status s] [--kind before_after|ab], show <id>, events <id> [--json] [--refresh], freeze <id> [--window before|after|observation] [--reason r] [--json], metrics [--json], or create --from <file|-> | --title <title> --line type:ref[@time] --metric pack/metric[:direction]"
    )

    64
  end
end
