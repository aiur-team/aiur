defmodule Aiur.ExperimentsCLI do
  @moduledoc "Experiments commands for the local control RPC."
  alias Aiur.{Experiments, JSONSafe}

  @switches [status: :string, kind: :string, json: :boolean, spec_json: :string, draft: :boolean, no_freeze: :boolean, title: :string, line: :string, metric: :keep, hypothesis: :string]
  @allowed %{list: [:status, :kind, :json], show: [:json], create: [:spec_json, :draft, :no_freeze, :json, :title, :line, :metric, :hypothesis]}

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
    if flags[:status] in [nil, "draft", "active", "concluded", "abandoned"] and flags[:kind] in [nil, "before_after", "ab"], do: result(Experiments.list(filters), flags, :list), else: usage(flags)
  end

  defp dispatch(:show, flags, [id]), do: result(Experiments.fetch(id), flags, {:show, id})

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

  defp result({:ok, data}, flags, verb) do
    normalized = JSONSafe.normalize(data)
    if flags[:json], do: IO.puts(Jason.encode!(normalized)), else: print_human(normalized, verb)
    if verb == :create and !flags[:no_freeze], do: flags[:error_fun].("baseline not frozen: freeze is not available in this build")
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
  defp print_error({path, message}, error_fun), do: error_fun.("#{path}: #{message}")
  defp print_error(reason, error_fun), do: error_fun.("aiur: experiments #{inspect(reason)}")

  defp print_human(rows, :list) do
    Enum.each(rows, fn row -> IO.puts("#{row["id"]}  #{row["status"] || "unreadable"}  #{row["kind"]}  #{row["title"]}") end)
  end

  defp print_human(data, _verb), do: IO.puts(Jason.encode!(data, pretty: true))

  defp usage(opts) do
    error_fun = Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1))
    error_fun.("aiur: experiments expects list [--status s] [--kind before_after|ab], show <id>, or create --from <file|-> | --title <title> --line type:ref[@time] --metric pack/metric[:direction]")

    64
  end
end
