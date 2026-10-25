defmodule Aiur.RunTelemetry.UsageCapture do
  @moduledoc """
  Records one `ticket_usage` lifecycle point per ticket when it turns terminal.

  The `Aiur.UsageAggregate` query runs in a task under the telemetry
  supervisor, never on the caller's path, and every failure degrades to a
  `coverage: "unavailable"` point carrying no numbers. A ticket is recorded at
  most once per boot unless its totals change.
  """

  use Agent

  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.TrackerIdentity
  alias Aiur.UsageAggregate

  @tasks Aiur.RunTelemetry.UsageTasks

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []), do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Schedules the capture for `ticket`; fail-open and never blocks the caller."
  @spec capture(String.t(), TrackerIdentity.t() | nil, keyword()) :: :ok
  def capture(ticket, identity, opts \\ []) when is_binary(ticket) do
    Task.Supervisor.start_child(Keyword.get(opts, :tasks, @tasks), fn -> run(ticket, identity, opts) end)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec run(String.t(), TrackerIdentity.t() | nil, keyword()) :: :ok
  def run(ticket, identity, opts \\ []) do
    metadata = usage_metadata(identity, Keyword.get(opts, :query, Application.get_env(:aiur, :run_telemetry_usage_query, &UsageAggregate.query/1)))

    if new_totals?(Keyword.get(opts, :name, __MODULE__), ticket, metadata) do
      Lifecycle.record(ticket, nil, :ticket_usage, :point, metadata, Keyword.take(opts, [:recorder]))
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp usage_metadata(identity, query) do
    true = TrackerIdentity.joinable?(identity)
    summary = query.(%{tickets: [identity]})

    case summary.health do
      {:unavailable, _reason} -> %{coverage: :unavailable}
      _health -> totals_metadata(summary)
    end
  rescue
    _error -> %{coverage: :unavailable}
  catch
    :exit, _reason -> %{coverage: :unavailable}
  end

  defp totals_metadata(%{totals: %{tokens: tokens, money: money}} = summary) do
    # ponytail: reports the first currency only; multi-currency tickets lose the rest.
    {{_basis, currency}, amount} = money |> Enum.sort() |> List.first() || {{nil, nil}, nil}

    %{
      input_tokens: Map.get(tokens, :input, 0),
      output_tokens: Map.get(tokens, :output, 0),
      cached_tokens: Map.get(tokens, :cached_input, 0),
      cost_amount: amount && Decimal.to_string(amount),
      cost_currency: currency,
      coverage: coverage(summary)
    }
  end

  defp coverage(%{coverage: %{selected_cells: cells, unknown_attribution: unknown, projection: projection}, health: health}) do
    clean? = Enum.all?(unknown, fn {_dimension, count} -> count == 0 end) and projection.partial_records == 0
    if clean? and health == :healthy and cells > 0, do: :complete, else: :partial
  end

  defp new_totals?(name, ticket, metadata) do
    Agent.get_and_update(name, fn seen ->
      if Map.get(seen, ticket) == metadata, do: {false, seen}, else: {true, Map.put(seen, ticket, metadata)}
    end)
  end
end
