defmodule Aiur.CommandsCLI do
  alias Aiur.Commands
  @moduledoc false

  alias Aiur.CommandsCLI.{Observation, Printer}
  alias Aiur.JSONSafe
  alias AiurWeb.OperatorControlCenter.DecisionProvider

  @filters ~w(all open blocking resolved needs-you with-executor from-executor)a

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    case build(opts) do
      {:ok, envelope} ->
        if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(envelope)), else: Printer.print_human(envelope)
        0

      {:error, reason} ->
        IO.puts(:stderr, "aiur: commands #{reason}")
        1
    end
  end

  @doc false
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ [])

  def build(opts) when is_list(opts) do
    with {:ok, request} <- request(opts),
         {:ok, page} <- list(request, opts),
         {:ok, counts} <- counts(opts),
         {:ok, selected} <- selected(request, opts) do
      captured_at = Keyword.get(opts, :now, DateTime.utc_now())
      {history, history_source} = history(opts)

      {:ok,
       %{
         schema_version: 1,
         page: "commands",
         snapshot: %{captured_at: captured_at},
         request: request,
         sources:
           %{
             decision_page: source(page.health),
             retained_counts: source(counts.health),
             history: history_source
           }
           |> maybe_put(:selected_decision, selected.health && source(selected.health)),
         data: %{
           page: page |> Map.drop([:health]) |> Map.update!(:decisions, &Enum.map(&1, fn row -> Observation.row(row, page, captured_at) end)),
           selected: Observation.row(selected.decision, %{health: selected.health}, captured_at),
           retained_counts: Map.drop(counts, [:health, :scope]),
           history: history
         },
         auxiliary: %{}
       }
       |> JSONSafe.normalize()}
    end
  end

  def build(_opts), do: {:error, "expects command options"}

  defp request(opts) do
    filter = if Keyword.get(opts, :blocking, false), do: :blocking, else: Keyword.get(opts, :filter, :all)
    decision_id = Keyword.get(opts, :decision_id)

    with {:ok, filter} <- filter(filter),
         :ok <- supported_query?(filter, opts),
         {:ok, query} <- query(filter, opts) do
      {:ok,
       %{filter: Atom.to_string(filter)}
       |> maybe_put(:decision_id, decision_id)
       |> Map.merge(query)}
    end
  end

  defp filter(filter) when is_binary(filter) do
    case Enum.find(@filters, &(Atom.to_string(&1) == filter)) do
      nil -> {:error, "accepts --filter all, open, blocking, resolved, needs-you, with-executor, or from-executor"}
      filter -> {:ok, filter}
    end
  end

  defp filter(filter) when filter in @filters, do: {:ok, filter}
  defp filter(_filter), do: {:error, "accepts --filter all, open, blocking, resolved, needs-you, with-executor, or from-executor"}

  defp supported_query?(filter, opts) do
    if filter != :all and (Keyword.has_key?(opts, :ticket) or Keyword.has_key?(opts, :search)) do
      {:error, "only supports --ticket and --search with --filter all"}
    else
      :ok
    end
  end

  defp query(filter, opts) do
    query = %{"limit" => Keyword.get(opts, :limit, 25)} |> maybe_put("cursor", Keyword.get(opts, :cursor))

    query =
      case filter do
        :blocking -> query |> Map.put("lifecycle", "open") |> Map.put("blocking", true)
        :open -> Map.put(query, "lifecycle", "open")
        :resolved -> Map.put(query, "lifecycle", "historic")
        :"needs-you" -> Map.merge(query, %{"lifecycle" => "open", "route" => "needs_you"})
        :"with-executor" -> Map.merge(query, %{"lifecycle" => "open", "route" => "with_executor"})
        :"from-executor" -> Map.merge(query, %{"lifecycle" => "open", "requester" => "executor"})
        :all -> query |> Map.put("lifecycle", "open") |> maybe_put("ticket", opts[:ticket]) |> maybe_put("search", opts[:search])
      end

    {:ok, query}
  end

  defp list(request, opts) do
    query = request |> Map.drop([:filter, :decision_id]) |> Map.new(fn {key, value} -> {to_string(key), value} end)

    case DecisionProvider.list(query, provider_opts(opts)) do
      {:ok, %{health: %{status: :unavailable}}} -> {:error, "retained data unavailable"}
      {:ok, page} -> {:ok, page}
      {:error, {:invalid_query, reason}} -> {:error, "received an invalid query (#{inspect(reason)})"}
    end
  end

  defp counts(opts), do: DecisionProvider.counts(provider_opts(opts))

  defp selected(request, opts) do
    case Map.get(request, :decision_id) do
      nil -> {:ok, %{decision: nil, health: nil}}
      decision_id -> selected_decision(decision_id, opts)
    end
  end

  defp selected_decision(decision_id, opts) do
    case DecisionProvider.detail(decision_id, provider_opts(opts)) do
      {:ok, %{decision: decision, health: health}} -> {:ok, %{decision: decision, health: health}}
      {:error, :not_found} -> {:error, "could not find decision #{inspect(decision_id)}"}
      {:error, {:indeterminate, _health}} -> {:error, "cannot determine whether decision #{inspect(decision_id)} exists; retained data is partial"}
      {:error, _reason} -> {:error, "could not read decision #{inspect(decision_id)}"}
    end
  end

  defp history(opts) do
    history_fun = Keyword.get(opts, :history_fun, fn -> Commands.history(server: Keyword.get(opts, :decision_store, Commands.default_store()), limit: 50) end)
    {history_fun.(), source(%{status: :available, partial?: false, reason: nil})}
  rescue
    _error -> {[], unavailable_source(:history_unavailable)}
  catch
    :exit, _reason -> {[], unavailable_source(:history_unavailable)}
  end

  defp provider_opts(opts) do
    [decision_store: Keyword.get(opts, :decision_store, Commands.default_store()), decision_metrics: Keyword.get(opts, :decision_metrics, Commands.default_metrics())]
  end

  defp source(health) do
    %{
      state: Map.get(health, :status, :unavailable),
      observed_at: nil,
      age_ms: nil,
      freshness: :unknown,
      partial: Map.get(health, :partial?, true),
      reasons: health |> Map.get(:reason) |> List.wrap() |> Enum.reject(&is_nil/1)
    }
  end

  defp unavailable_source(reason), do: source(%{status: :unavailable, partial?: true, reason: reason})

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
