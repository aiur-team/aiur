defmodule Aiur.CommandsCLI do
  @moduledoc false

  alias Aiur.{DecisionHistory, JSONSafe}
  alias AiurWeb.OperatorControlCenter.DecisionProvider

  @filters ~w(all open blocking resolved)a

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    case build(opts) do
      {:ok, envelope} ->
        if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(envelope)), else: print_human(envelope)
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
           page: Map.drop(page, [:health]),
           selected: selected.decision,
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
      nil -> {:error, "accepts --filter all, open, blocking, or resolved"}
      filter -> {:ok, filter}
    end
  end

  defp filter(filter) when filter in @filters, do: {:ok, filter}
  defp filter(_filter), do: {:error, "accepts --filter all, open, blocking, or resolved"}

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
        :all -> query |> Map.put("lifecycle", "open") |> maybe_put("ticket", opts[:ticket]) |> maybe_put("search", opts[:search])
      end

    {:ok, query}
  end

  defp list(request, opts) do
    query = request |> Map.drop([:filter, :decision_id]) |> Map.new(fn {key, value} -> {to_string(key), value} end)

    case DecisionProvider.list(query, provider_opts(opts)) do
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
    history_fun = Keyword.get(opts, :history_fun, fn -> DecisionHistory.list(server: Keyword.get(opts, :decision_store, Aiur.DecisionStore), limit: 50) end)
    {history_fun.(), source(%{status: :available, partial?: false, reason: nil})}
  rescue
    _error -> {[], unavailable_source(:history_unavailable)}
  catch
    :exit, _reason -> {[], unavailable_source(:history_unavailable)}
  end

  defp provider_opts(opts) do
    [decision_store: Keyword.get(opts, :decision_store, Aiur.DecisionStore), decision_metrics: Keyword.get(opts, :decision_metrics, Aiur.DecisionMetrics)]
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

  defp print_human(envelope) do
    IO.puts("Commands captured #{get_in(envelope, ["snapshot", "captured_at"])}")
    Enum.each(envelope["sources"], fn {name, value} -> IO.puts("#{name}: #{value["state"]}; freshness #{value["freshness"]}") end)

    case get_in(envelope, ["data", "selected"]) do
      nil -> print_rows(get_in(envelope, ["data", "page", "decisions"]) || [], get_in(envelope, ["snapshot", "captured_at"]))
      decision -> print_detail(decision, get_in(envelope, ["snapshot", "captured_at"]), get_in(envelope, ["data", "history"]) || [])
    end
  end

  defp print_rows([], _captured_at), do: IO.puts("No Commands match this filter.")

  defp print_rows(rows, captured_at) do
    if IO.ANSI.enabled?() do
      IO.puts("ID  TICKET  ORIGIN  AGE  URGENCY  BLOCKING  LIFECYCLE  SUPERSEDED  QUESTION")

      Enum.each(rows, fn row ->
        ticket = get_in(row, ["ticket", "identifier"]) || "-"
        ticket_title = get_in(row, ["ticket", "title"])
        origin = get_in(row, ["source", "agent_id"]) || "unknown"

        IO.puts(
          "#{row["decision_id"]}  #{ticket_label(ticket, ticket_title)}  #{origin}  #{age(row["created_at"], captured_at)}  #{row["urgency"]}  #{row["blocking"]}  #{row["lifecycle"]}  #{row["superseded?"]}  #{row["question"]}"
        )
      end)
    else
      Enum.each(rows, &print_row(&1, captured_at))
    end
  end

  defp print_row(row, captured_at) do
    IO.puts("Command: #{row["decision_id"]}")
    IO.puts("Ticket: #{ticket_label(get_in(row, ["ticket", "identifier"]) || "-", get_in(row, ["ticket", "title"]))}")
    IO.puts("Question: #{row["question"]}")
    IO.puts("Origin: #{get_in(row, ["source", "agent_id"]) || "unknown"}")
    IO.puts("Age: #{age(row["created_at"], captured_at)}")
    IO.puts("Urgency: #{row["urgency"]}; blocking: #{row["blocking"]}; lifecycle: #{row["lifecycle"]}; superseded: #{row["superseded?"]}")
  end

  defp print_detail(decision, captured_at, history) do
    IO.puts("#{decision["decision_id"]} · #{decision["lifecycle"]} · blocking #{decision["blocking"]} · superseded #{decision["superseded?"]}")
    IO.puts(decision["question"])
    IO.puts("Urgency: #{decision["urgency"]}")
    IO.puts("Origin: #{get_in(decision, ["source", "agent_id"]) || "unknown"}")
    IO.puts("Age: #{age(decision["created_at"], captured_at)}")
    IO.puts("Context: #{get_in(decision, ["context", "short"]) || "none"}")
    IO.puts("Consequence of delay: #{decision["consequence_of_delay"] || "none"}")
    IO.puts("Recommendation: #{recommendation(decision["recommendation"])}")

    Enum.each(decision["options"] || [], fn option ->
      IO.puts("Option #{option["id"]}: #{option["label"]}#{if option["risk"], do: " (#{option["risk"]} risk)", else: ""}")
      IO.puts("  Description: #{option["description"] || "none"}")
      IO.puts("  Benefits: #{option["benefits"] || "none"}")
      IO.puts("  Drawbacks: #{option["drawbacks"] || "none"}")
    end)

    print_history(Enum.filter(history, &(&1["decision_id"] == decision["decision_id"])))
  end

  defp age(created_at, captured_at) when is_binary(created_at) and is_binary(captured_at) do
    with {:ok, created_at, _offset} <- DateTime.from_iso8601(created_at),
         {:ok, captured_at, _offset} <- DateTime.from_iso8601(captured_at) do
      "#{max(DateTime.diff(captured_at, created_at), 0)}s"
    else
      _invalid -> "unknown"
    end
  end

  defp age(_created_at, _captured_at), do: "unknown"

  defp ticket_label(ticket, title) when is_binary(title) and title != "", do: "#{ticket} (#{title})"
  defp ticket_label(ticket, _title), do: ticket

  defp recommendation(%{"option_id" => option_id, "reason" => reason}), do: "#{option_id}: #{reason || "no rationale"}"
  defp recommendation(_recommendation), do: "none"

  defp print_history([]), do: IO.puts("History: none")

  defp print_history(history) do
    IO.puts("History:")
    Enum.each(history, fn entry -> IO.puts("- #{entry["changed_at"] || "unknown"}: #{entry["change"] || "unknown"}") end)
  end
end
