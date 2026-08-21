defmodule Aiur.GitHubUsageCLI do
  @moduledoc """
  `aiur github-usage` — who is driving the shared GitHub hourly budget.

  One command, one question: per actor (the daemon and each agent workspace),
  how much of the hourly Core and GraphQL ceilings has been used and when does
  the window roll. The broker's `admissions` already carried the endpoint family
  for every admitted request; this reads them per consumer, so the answer to
  "daemon or agents?" is a table rather than a reconciliation delta.

  The ceilings are request-count ceilings, not GraphQL point budgets. The
  broker sees the request, never the point price GitHub charged for a query, so
  `used`/`limit` here count admissions. Point-accurate attribution stays with
  `aiur github-cost`; the per-actor report is the coarser guard that stops one
  actor from exhausting the shared hourly budget and 429ing everyone else.
  """

  alias Aiur.GitHub.Budget
  alias Aiur.JSONSafe

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    case build(opts) do
      {:ok, envelope} ->
        if Keyword.get(opts, :json, false),
          do: IO.puts(Jason.encode!(envelope)),
          else: print_human(envelope)

        0

      {:error, reason} ->
        IO.puts(:stderr, "aiur: github-usage #{reason}")
        1
    end
  end

  @doc """
  The per-actor usage envelope, with no output of its own.

  `usage_fun` is the seam: the default reads the live broker, and tests hand in
  a fixed snapshot so the rendering can be asserted without a broker.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ []) do
    usage_fun = Keyword.get(opts, :usage_fun, &Budget.usage/0)

    case usage_fun.() do
      %{actors: actors} when is_list(actors) ->
        {:ok, envelope(actors, opts)}

      _unavailable ->
        {:error, "could not read the GitHub usage broker"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> {:error, "the GitHub usage broker is not running"}
  end

  defp envelope(actors, opts) do
    JSONSafe.normalize(%{
      schema_version: 1,
      page: "github-usage",
      snapshot: %{captured_at: Keyword.get(opts, :now, DateTime.utc_now())},
      data: %{actors: Enum.map(actors, &present_actor/1)}
    })
  end

  defp present_actor(actor) do
    %{
      actor: actor_label(actor),
      core: Map.get(actor, :core, %{}),
      graphql: Map.get(actor, :graphql, %{})
    }
  end

  defp actor_label(actor) do
    case Map.get(actor, :consumer_label) do
      label when is_binary(label) and label != "" -> label
      _missing -> Map.get(actor, :consumer_key, "unknown")
    end
  end

  defp print_human(envelope) do
    actors = envelope["data"]["actors"]

    now =
      case DateTime.from_iso8601(envelope["snapshot"]["captured_at"]) do
        {:ok, parsed, _offset} -> parsed
        _invalid -> DateTime.utc_now()
      end

    if actors == [] do
      IO.puts("No GitHub usage has been observed in the current window.")
    else
      IO.puts("GitHub usage by actor (rolling hour; limits are request-count ceilings; 0 = no ceiling)")
      IO.puts("")

      Enum.each(actors, fn actor ->
        IO.puts(actor["actor"])
        IO.puts("  core    #{usage_line(actor["core"], now)}")
        IO.puts("  graphql #{usage_line(actor["graphql"], now)}")
      end)
    end
  end

  defp usage_line(figure, now) when is_map(figure) do
    used = Map.get(figure, "used", 0)
    limit = Map.get(figure, "limit", 0)
    reset_at_ms = Map.get(figure, "reset_at_ms")

    ceiling = if limit > 0 and used >= limit, do: " (at ceiling)", else: ""

    "#{used}/#{limit}#{ceiling}#{reset_suffix(reset_at_ms, now)}"
  end

  defp usage_line(_figure, _now), do: "unknown"

  defp reset_suffix(nil, _now), do: ""

  defp reset_suffix(reset_at_ms, now) when is_integer(reset_at_ms) do
    seconds_remaining = max(div(reset_at_ms, 1_000) - DateTime.to_unix(now), 0)
    "  resets in " <> format_seconds(seconds_remaining)
  end

  defp reset_suffix(_reset_at_ms, _now), do: ""

  defp format_seconds(0), do: "now"

  defp format_seconds(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_seconds(seconds) when seconds < 3_600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_seconds(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"

  defp format_seconds(seconds), do: "#{div(seconds, 86_400)}d"
end
