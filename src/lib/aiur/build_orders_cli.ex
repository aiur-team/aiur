defmodule Aiur.BuildOrdersCLI do
  @moduledoc false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.{JSONSafe, TrackerIdentity}
  alias AiurWeb.BuildOrder.{DataSource, Runtime}
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    case build(opts) do
      {:ok, envelope} ->
        if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(envelope)), else: print_human(envelope)
        0

      {:error, reason} ->
        IO.puts(:stderr, "aiur: build-orders #{reason}")
        1
    end
  end

  @doc false
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ [])

  def build(opts) when is_list(opts) do
    source = Keyword.get(opts, :source, Application.get_env(:aiur, :build_order_data_source, DataSource))
    captured_at = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, request} <- request(opts),
         %Snapshot{} = catalog_snapshot <- Runtime.safe_source_call(source, :catalog, [], nil),
         {:ok, envelope} <- envelope(request, catalog_snapshot, source, captured_at) do
      {:ok, envelope |> plain() |> JSONSafe.normalize()}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "could not read the Build Order catalog"}
    end
  end

  def build(_opts), do: {:error, "expects command options"}

  defp request(opts) do
    case Keyword.get(opts, :root) do
      nil -> {:ok, %{}}
      root when is_binary(root) and root != "" -> {:ok, %{root: root}}
      _root -> {:error, "accepts one non-empty Build Order root"}
    end
  end

  defp envelope(request, %Snapshot{} = snapshot, _source, captured_at) when map_size(request) == 0 do
    {:ok,
     %{
       schema_version: 1,
       page: "build-orders",
       snapshot: %{captured_at: captured_at},
       request: %{},
       sources: %{planning_catalog: planning_source(snapshot, captured_at)},
       data: %{catalog: snapshot.data},
       auxiliary: %{}
     }}
  end

  defp envelope(%{root: root}, %Snapshot{data: %Catalog{} = catalog}, source, captured_at) do
    with {:ok, identity} <- root_identity(catalog, root),
         {:ok, %Snapshot{} = planning} <- Runtime.safe_source_call(source, :demand, [identity], {:error, :unavailable}),
         sources when is_map(sources) <- Runtime.safe_source_call(source, :load_runtime_sources, [], %{}) do
      model = BuildOrderPresenter.present(planning, Map.get(sources, :execution), Map.get(sources, :activity))
      grid = BuildOrderGridModel.build(model, nil)

      {:ok,
       %{
         schema_version: 1,
         page: "build-orders",
         snapshot: %{captured_at: captured_at},
         request: %{root: root},
         sources: %{
           planning_graph: planning_source(planning, captured_at),
           execution: runtime_source(model.execution_health),
           activity: runtime_source(model.activity_health)
         },
         data: %{
           root: model.root,
           graph: graph(model, grid),
           runtime: %{execution: model.execution_health, activity: model.activity_health}
         },
         auxiliary: %{}
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "could not read Build Order #{inspect(root)}"}
    end
  end

  defp envelope(_request, _snapshot, _source, _captured_at), do: {:error, "could not read the Build Order catalog"}

  defp root_identity(%Catalog{entries: entries}, root) do
    case Enum.filter(entries, &(match?(%{identity: %TrackerIdentity{identifier: ^root}}, &1) and TrackerIdentity.joinable?(&1.identity))) do
      [%{identity: identity}] -> {:ok, identity}
      [] -> {:error, "could not find Build Order #{inspect(root)}"}
      _duplicates -> {:error, "cannot select ambiguous Build Order #{inspect(root)}"}
    end
  end

  defp graph(model, grid) do
    %{
      status: model.status,
      summary: model.summary,
      completion: grid.overall_pct,
      lanes: grid.columns,
      waves: grid.waves,
      members: members(model, grid),
      edges: edges(grid),
      diagnostics: model.diagnostics
    }
  end

  defp members(model, grid) do
    nodes = Map.new(model.nodes, &{&1.key, &1})
    incoming = Enum.group_by(grid.edges, & &1.target)

    Enum.map(grid.cards, fn card ->
      node = Map.get(nodes, card.key)
      completion_known? = card.completion_known

      %{
        id: card.id,
        title: card.title,
        lane: card.lane,
        phase: card.phase,
        complexity: card.complexity,
        state: node && node.plan.lifecycle.state,
        display_state: card.status_word,
        lifecycle: node && node.plan.lifecycle,
        completion: if(completion_known?, do: card.progress, else: nil),
        completion_state: if(completion_known?, do: :known, else: :unresolved),
        blocked_by: incoming |> Map.get(card.id, []) |> Enum.map(&%{from: &1.source, state: &1.state})
      }
    end)
  end

  defp edges(grid) do
    Enum.map(grid.edges, fn edge ->
      %{from: edge.source, to: edge.target, direction: :blocker_to_blocked, state: edge.state}
    end)
  end

  defp planning_source(%Snapshot{data: data, health: health}, captured_at) do
    source(health, captured_at, empty?: empty?(data), diagnostics: diagnostics(data))
  end

  defp planning_source(_snapshot, _captured_at), do: unavailable_source(:planning_unavailable)

  defp runtime_source(:available), do: unknown_source(:available)
  defp runtime_source(_health), do: unavailable_source(:runtime_unavailable)

  defp source(%ProviderHealth{} = health, captured_at, opts) do
    state =
      cond do
        health.state == :healthy and Keyword.get(opts, :empty?, false) -> :empty
        health.state == :healthy -> :available
        health.state == :stale -> :stale
        health.state == :structurally_invalid -> :invalid
        true -> :unavailable
      end

    %{
      state: state,
      observed_at: health.observed_at,
      age_ms: age_ms(health.observed_at, captured_at),
      freshness: freshness(health.state),
      partial: not health.complete?,
      reasons: Enum.reject([health.failure | Keyword.get(opts, :diagnostics, [])], &is_nil/1)
    }
  end

  defp source(_health, _captured_at, _opts), do: unavailable_source(:planning_unavailable)

  defp unknown_source(state), do: %{state: state, observed_at: nil, age_ms: nil, freshness: :unknown, partial: false, reasons: []}
  defp unavailable_source(reason), do: %{state: :unavailable, observed_at: nil, age_ms: nil, freshness: :unknown, partial: true, reasons: [reason]}

  defp freshness(:healthy), do: :current
  defp freshness(:stale), do: :stale
  defp freshness(_state), do: :unknown

  defp age_ms(%DateTime{} = observed_at, %DateTime{} = captured_at), do: max(DateTime.diff(captured_at, observed_at, :millisecond), 0)
  defp age_ms(_observed_at, _captured_at), do: nil

  defp empty?(%Catalog{entries: []}), do: true
  defp empty?(%{members: []}), do: true
  defp empty?(_data), do: false

  defp diagnostics(%{diagnostics: diagnostics}) when is_list(diagnostics), do: Enum.map(diagnostics, &Map.get(&1, :code))
  defp diagnostics(_data), do: []

  defp print_human(envelope) do
    IO.puts("Build Orders captured #{get_in(envelope, ["snapshot", "captured_at"])}")

    envelope["sources"]
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {name, source} ->
      IO.puts("#{name}: #{source["state"]}; freshness #{source["freshness"]}; age #{source["age_ms"] || "unknown"}ms")
    end)

    if Map.has_key?(envelope["data"], "catalog"), do: print_catalog(envelope["data"]["catalog"]), else: print_selected(envelope)
  end

  defp print_catalog(%{"entries" => []}), do: IO.puts("No Build Orders for this repository.")

  defp print_catalog(%{"entries" => entries}) do
    if IO.ANSI.enabled?() do
      IO.puts("ROOT  TITLE  COMPLETION  MEMBERS  EPICS  WAVES")

      Enum.each(entries, fn entry ->
        IO.puts(
          "#{get_in(entry, ["identity", "identifier"]) || "unknown"}  #{entry["title"]}  #{completion(entry["progress"])}  #{entry["member_count"] || "unresolved"}  #{entry["epic_count"] || "unresolved"}  #{entry["phase_count"] || "unresolved"}"
        )
      end)
    else
      Enum.each(entries, fn entry ->
        IO.puts("#{get_in(entry, ["identity", "identifier"]) || "unknown"}: #{entry["title"]} (completion #{completion(entry["progress"])}, members #{entry["member_count"] || "unresolved"})")
      end)
    end
  end

  defp print_catalog(_catalog), do: IO.puts("Build Order catalog unavailable.")

  defp print_selected(envelope) do
    root = get_in(envelope, ["data", "root", "title"]) || "Build Order"
    IO.puts(root)

    Enum.each(get_in(envelope, ["data", "graph", "members"]) || [], fn member ->
      blockers =
        member["blocked_by"]
        |> Enum.map(&"#{&1["from"]} (#{&1["state"]})")
        |> case do
          [] -> "none"
          values -> Enum.join(values, ", ")
        end

      IO.puts("#{member["id"]}: #{member["title"]}")
      IO.puts("  Lane: #{member["lane"]}; Phase: #{member["phase"]}; Complexity: #{member["complexity"] || "unresolved"}; State: #{member["state"]}; Display state: #{member["display_state"]}")
      IO.puts("  Completion: #{completion(member["completion"])}; blocked by #{blockers}")
    end)
  end

  defp completion(value) when is_integer(value), do: "#{value}%"
  defp completion(_value), do: "unresolved"

  defp plain(%DateTime{} = value), do: value
  defp plain(%{__struct__: _} = value), do: value |> Map.from_struct() |> plain()
  defp plain(value) when is_map(value), do: Map.new(value, fn {key, item} -> {key, plain(item)} end)
  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value), do: value
end
