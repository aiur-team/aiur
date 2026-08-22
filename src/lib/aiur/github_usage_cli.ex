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

  `schema_version` is `2` on every envelope, including the single-credential
  default where the payload is byte-identical to version 1. The version states
  what this command's schema *can* contain, not what one payload happens to
  contain — making it track the operator's credential count would mean one
  binary emitting two versions of one schema, and a consumer watching the number
  flip when someone edits a config file. Consumers should branch on whether
  `data.credentials` is present, which is the honest signal.
  """

  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.CredentialUsage
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
    rows = CredentialUsage.rows(Keyword.put(opts, :usage_fun, fn -> %{actors: actors} end))

    JSONSafe.normalize(%{
      schema_version: 2,
      page: "github-usage",
      snapshot: %{captured_at: Keyword.get(opts, :now, DateTime.utc_now())},
      data: %{actors: Enum.map(actors, &present_actor/1)}
    })
    |> put_credential_view(rows, opts)
  end

  # With one credential — the default — the per-actor table is the whole answer
  # and the report is unchanged. The credential sections exist to compare
  # credentials, and there is nothing to compare.
  defp put_credential_view(envelope, rows, _opts) when length(rows) < 2, do: envelope

  defp put_credential_view(envelope, rows, opts) do
    view =
      JSONSafe.normalize(%{
        credentials: Enum.map(rows, &present_credential/1),
        pool: CredentialUsage.pool(Keyword.put(opts, :rows, rows))
      })

    update_in(envelope["data"], &Map.merge(&1, view))
  end

  defp present_credential(row) do
    %{
      id: row.id,
      kind: row.kind,
      identity: row.identity,
      writes: row.writes?,
      primary: row.primary?,
      available: row.available?,
      actors: row.actors,
      admissions: row.admissions,
      windows: row.windows
    }
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

    print_credentials(envelope["data"]["credentials"])
    print_pool(envelope["data"]["pool"])
  end

  # Absent unless the envelope carries a credential section, which `envelope/2`
  # adds only when more than one credential is configured. With one credential
  # the per-actor table above is the whole answer and this prints nothing.
  defp print_credentials(credentials) when is_list(credentials) and credentials != [] do
    IO.puts("")
    IO.puts("Credentials (admissions are Aiur's request counts; window is GitHub's own figure for that credential)")
    IO.puts("")

    Enum.each(credentials, &print_credential/1)
  end

  defp print_credentials(_credentials), do: :ok

  defp print_credential(credential) do
    IO.puts("#{credential["id"]}  #{credential_traits(credential)}")

    Enum.each(["core", "graphql"], fn resource ->
      admissions = get_in(credential, ["admissions", resource]) || %{}
      IO.puts("  #{String.pad_trailing(resource, 7)} #{admission_line(admissions)}   window #{window_line(get_in(credential, ["windows", resource]))}")
    end)
  end

  defp credential_traits(credential) do
    [
      credential["kind"],
      credential["identity"] || "unknown-identity",
      if(credential["writes"], do: "read+write", else: "read-only"),
      if(credential["available"], do: "available", else: "TOKEN UNAVAILABLE")
    ]
    |> Enum.join(", ")
    |> then(&"(#{&1})")
  end

  defp admission_line(admissions) do
    limit = Map.get(admissions, "limit", 0)
    "admitted #{Map.get(admissions, "used", 0)}/#{if limit == 0, do: "no ceiling", else: limit}"
  end

  # `nil` and `0` are different facts. A credential with no window has not been
  # called this hour; a credential with `remaining: 0` is exhausted.
  defp window_line(window) when is_map(window) do
    "#{Map.get(window, "remaining")} of #{Map.get(window, "limit")} left"
  end

  defp window_line(_window), do: "not observed this window"

  defp print_pool(pool) when is_map(pool) and map_size(pool) > 0 do
    IO.puts("")

    Enum.each(pool, fn {resource, figures} ->
      IO.puts("#{resource} pool: #{pool_line(figures)}")
    end)
  end

  defp print_pool(_pool), do: :ok

  # A pool total is a ceiling, not a balance: the credentials' hourly windows
  # reset at different moments, so the pool never holds the sum at any instant.
  # And a total built from a subset of the pool is a floor, which is worth
  # saying out loud rather than printing as if it were the figure.
  defp pool_line(%{"observed_credentials" => 0, "configured_credentials" => configured}),
    do: "no credential observed yet (#{configured} configured)"

  defp pool_line(figures) do
    coverage =
      if figures["complete?"],
        do: "all #{figures["configured_credentials"]} credentials observed",
        else: "PARTIAL — #{figures["observed_credentials"]} of #{figures["configured_credentials"]} credentials observed, so this is a floor"

    "#{figures["remaining"]} remaining of #{figures["limit"]} across the pool (#{coverage}; windows reset independently, so the pool never holds this at one instant)"
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
