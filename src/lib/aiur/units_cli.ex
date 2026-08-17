defmodule Aiur.UnitsCLI do
  @moduledoc false

  require Logger

  alias Aiur.JSONSafe
  alias AiurWeb.OperatorControlCenter.{PayloadLoader, UnitsPolicy, UnitsPresentation, UnitsPresenter}

  @formats [:auto, :table, :records]
  @table_min_width 120

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    with {:ok, format} <- format(opts),
         {:ok, envelope} <- build(opts) do
      if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(envelope)), else: print_human(envelope, format)
      0
    else
      {:error, reason} ->
        IO.puts(:stderr, "aiur: units #{reason}")
        1
    end
  end

  @doc false
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ [])

  def build(opts) when is_list(opts) do
    with {:ok, selection} <- selection(opts),
         {:ok, catalog} <- catalog(opts) do
      captured_at = Keyword.get(opts, :now, DateTime.utc_now())
      view = UnitsPresenter.project(catalog, selection)

      {:ok,
       %{
         schema_version: 1,
         page: "units",
         snapshot: %{captured_at: captured_at},
         request: request(selection),
         sources: %{units_catalog: source(catalog, captured_at)},
         data: %{catalog: public_catalog(catalog), view: public_view(view, captured_at)},
         auxiliary: %{}
       }
       |> JSONSafe.normalize()}
    end
  end

  def build(_opts), do: {:error, "expects units options"}

  defp selection(opts) do
    scope = Keyword.get(opts, :scope, UnitsPolicy.default_selection().scope)
    conditions = opts |> Keyword.get(:conditions, []) |> List.wrap() |> Enum.flat_map(&split_conditions/1)

    with {:ok, scope} <- scope(scope),
         {:ok, conditions} <- conditions(conditions) do
      {:ok, UnitsPolicy.normalize_selection(%{scope: scope, conditions: conditions})}
    end
  end

  defp scope(scope) when is_atom(scope) do
    if scope in UnitsPolicy.scopes(), do: {:ok, scope}, else: {:error, "accepts --scope live, unfinished, all, or none"}
  end

  defp scope(scope) when is_binary(scope) do
    case Enum.find(UnitsPolicy.scopes(), &(Atom.to_string(&1) == String.downcase(String.trim(scope)))) do
      nil -> {:error, "accepts --scope live, unfinished, all, or none"}
      scope -> {:ok, scope}
    end
  end

  defp scope(_scope), do: {:error, "accepts --scope live, unfinished, all, or none"}

  defp format(opts) do
    case Keyword.get(opts, :format, :auto) do
      format when format in @formats -> {:ok, format}
      format when is_binary(format) -> named_format(String.downcase(String.trim(format)))
      _format -> format_error()
    end
  end

  defp named_format(format) do
    case Enum.find(@formats, &(Atom.to_string(&1) == format)) do
      nil -> format_error()
      format -> {:ok, format}
    end
  end

  defp format_error, do: {:error, "accepts --format auto, table, or records"}

  defp conditions(conditions) do
    normalized =
      conditions
      |> Enum.map(&normalize_condition/1)

    if Enum.any?(normalized, &is_nil/1) do
      {:error, "accepts --condition active, alert, paused, queued, or finished"}
    else
      {:ok, Enum.uniq(normalized)}
    end
  end

  defp split_conditions(value) when is_binary(value), do: String.split(value, ",", trim: true)
  defp split_conditions(value), do: [value]

  defp normalize_condition(condition) when is_atom(condition) do
    if condition in visible_conditions(), do: condition
  end

  defp normalize_condition(condition) when is_binary(condition) do
    Enum.find(visible_conditions(), &(Atom.to_string(&1) == String.downcase(String.trim(condition))))
  end

  defp normalize_condition(_condition), do: nil

  defp visible_conditions, do: UnitsPolicy.visible_conditions()

  defp catalog(opts) do
    payload_fun = Keyword.get(opts, :payload_fun, fn -> PayloadLoader.load(:fresh) end)

    case payload_fun.() do
      %{units: catalog} when is_map(catalog) -> {:ok, catalog}
      %{"units" => catalog} when is_map(catalog) -> {:ok, catalog}
      _payload -> {:ok, unavailable_catalog()}
    end
  rescue
    error ->
      Logger.warning("units CLI could not read the Units catalog: #{Exception.message(error)}")
      {:ok, unavailable_catalog()}
  catch
    kind, reason ->
      Logger.warning("units CLI could not read the Units catalog: #{inspect(kind)} #{inspect(reason)}")
      {:ok, unavailable_catalog()}
  end

  defp unavailable_catalog do
    %{
      status: :unavailable,
      message: "Fleet data is unavailable.",
      truncated?: false,
      snapshot: %{freshness: %{membership: %{status: :unavailable}}, rows: []}
    }
  end

  defp request(selection) do
    %{
      scope: Atom.to_string(selection.scope),
      conditions: Enum.map(selection.conditions, &Atom.to_string/1)
    }
  end

  defp source(catalog, captured_at) do
    {observed_at, freshness} = catalog_freshness(catalog)
    state = source_state(catalog)

    %{
      state: state,
      observed_at: observed_at,
      age_ms: age_ms(observed_at, captured_at),
      freshness: freshness,
      partial: Map.get(catalog, :truncated?, false) == true,
      reasons: source_reasons(state, Map.get(catalog, :truncated?, false) == true)
    }
  end

  defp catalog_freshness(catalog) do
    freshness = get_in(catalog, [:snapshot, :freshness, :membership]) || %{}
    observed_at = Map.get(freshness, :observed_at)

    case {normalizable_datetime(observed_at), Map.get(freshness, :status)} do
      {nil, _status} -> {nil, :unknown}
      {observed_at, status} -> {observed_at, freshness_status(status)}
    end
  end

  defp freshness_status(status) when status in [:fresh, :current], do: :current
  defp freshness_status(:stale), do: :stale
  defp freshness_status(_status), do: :unknown

  defp normalizable_datetime(%DateTime{} = value), do: value

  defp normalizable_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp normalizable_datetime(_value), do: nil

  defp age_ms(nil, _captured_at), do: nil

  defp age_ms(observed_at, %DateTime{} = captured_at),
    do: max(DateTime.diff(captured_at, observed_at, :millisecond), 0)

  defp age_ms(_observed_at, _captured_at), do: nil

  defp source_state(%{status: :ready, truncated?: true}), do: :partial
  defp source_state(%{status: :ready}), do: :available
  defp source_state(%{status: status}) when status in [:empty, :stale, :unavailable], do: status
  defp source_state(_catalog), do: :unavailable

  defp source_reasons(:unavailable, _partial?), do: ["catalog_unavailable"]
  defp source_reasons(:stale, true), do: ["catalog_stale", "catalog_partial"]
  defp source_reasons(:stale, false), do: ["catalog_stale"]
  defp source_reasons(:partial, _partial?), do: ["catalog_partial"]
  defp source_reasons(_state, _partial?), do: []

  defp public_catalog(catalog) do
    if Map.get(catalog, :status) == :unavailable do
      Map.update(catalog, :snapshot, %{rows: nil}, &Map.put(&1, :rows, nil))
    else
      catalog
    end
  end

  defp public_view(view, captured_at) do
    view
    |> Map.update(:rows, nil, fn rows -> Enum.map(rows, &present_row(&1, captured_at)) end)
    |> Map.drop([:snapshot])
    |> then(fn view -> if Map.get(view, :status) == :unavailable, do: Map.put(view, :rows, nil), else: view end)
  end

  defp present_row(row, captured_at), do: Map.put(row, :presentation, UnitsPresentation.present(row, captured_at))

  defp print_human(envelope, format) do
    captured_at = get_in(envelope, ["snapshot", "captured_at"])
    source = get_in(envelope, ["sources", "units_catalog"])

    IO.puts("Units captured #{captured_at}")
    IO.puts("units_catalog: #{source["state"]}; freshness #{source["freshness"]}#{age_label(source["age_ms"])}")
    print_warning(source)

    case get_in(envelope, ["data", "view", "rows"]) do
      nil -> IO.puts("No live units; units have not been observed.")
      [] -> print_empty(envelope)
      rows when is_list(rows) -> print_rows(rows, format)
    end
  end

  defp age_label(nil), do: "; age unknown"
  defp age_label(age_ms), do: "; age #{age_ms}ms"

  defp print_warning(%{"state" => state, "reasons" => reasons}) when state in ["partial", "stale", "unavailable"],
    do: IO.puts("Warning: #{Enum.join(reasons, ", ")}")

  defp print_warning(_source), do: :ok

  defp print_empty(envelope) do
    view = get_in(envelope, ["data", "view"])

    cond do
      view["zero_result?"] -> IO.puts("No units match this valid scope and condition selection.")
      view["status"] == "empty" -> IO.puts("No units in this run yet.")
      true -> IO.puts("No Units match the selected view.")
    end
  end

  defp print_rows(rows, format) do
    case resolve_format(format) do
      :table -> print_table(rows)
      :records -> Enum.each(rows, &print_record/1)
    end
  end

  # `auto` prefers the table only on a real terminal wide enough to hold it.
  # `:io.columns/0` answers both questions; ANSI support answers neither.
  defp resolve_format(:table), do: :table
  defp resolve_format(:records), do: :records

  defp resolve_format(:auto) do
    case :io.columns() do
      {:ok, width} when width >= @table_min_width -> :table
      _narrow_or_not_a_terminal -> :records
    end
  end

  defp print_table(rows) do
    cells = Enum.map(rows, &[identifier(&1), unit_label(&1), ticket_label(&1), latest_label(&1), command_label(&1)])
    widths = column_widths([["ID", "UNIT", "TICKET", "LATEST", "COMMAND"] | cells])

    Enum.each([["ID", "UNIT", "TICKET", "LATEST", "COMMAND"] | cells], &IO.puts(table_line(&1, widths)))
  end

  defp column_widths(rows) do
    Enum.reduce(rows, List.duplicate(0, 5), fn row, widths ->
      Enum.zip_with(row, widths, fn cell, width -> max(String.length(cell), width) end)
    end)
  end

  defp table_line(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
    |> String.trim_trailing()
  end

  defp print_record(row) do
    IO.puts("ID: #{identifier(row)}")
    IO.puts("Unit: #{unit_label(row)}")
    IO.puts("Ticket: #{ticket_label(row)}")
    IO.puts("Latest: #{latest_label(row)}")
    IO.puts("Command: #{command_label(row)}")
  end

  defp identifier(row), do: get_in(row, ["identity", "identifier"]) || "unknown"

  defp unit_label(row) do
    unit = row["presentation"]["unit"]

    [unit["provider"], complexity_label(unit["complexity"]), unit["model"], unit["priority"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp complexity_label(complexity) when is_integer(complexity), do: "Cx:#{complexity}"
  defp complexity_label(_complexity), do: nil

  defp ticket_label(row) do
    state = row["build_lane"] || row["tracker_state"] || "state unknown"
    "#{row["title"] || "Title unknown"} (#{state})"
  end

  defp latest_label(row) do
    latest = row["presentation"]["latest"]
    "#{latest["text"]}; #{latest["progress"]}; #{latest["runtime"]}"
  end

  defp command_label(row) do
    command = row["presentation"]["command"]
    "#{get_in(command, ["control", "label"])}; chat #{command["chat"]}; remote control #{command["remote_control"]}; read-only"
  end
end
