defmodule AiurWeb.Api.Usage.TicketUsage do
  @moduledoc """
  Versioned per-ticket model-usage read shared by
  `GET /api/v1/:issue_identifier/usage` and `aiur ticket-usage`.

  The display issue number is never a usage join key. The retained
  `Aiur.UsageLedger` records carry the repository-qualified
  `Aiur.TrackerIdentity` each envelope was attributed to, so the number is
  resolved there, in the configured repository only, to the opaque identities
  the aggregate is keyed by. The numbers then come from the
  `Aiur.UsageAggregate` projection of that same ledger through
  `Aiur.Usage.GroupedScopes`, so this read reports what the dashboard and
  `mix aiur.cost_report` report, never a second accounting.

  A ticket whose raw ledger records have all been retired by compaction can no
  longer be resolved by number. When the ledger shows a retired prefix, that miss
  is `:usage_unresolvable` rather than `:usage_not_found`, because the ticket may
  have spent in the retired range.
  """

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.{JSONSafe, TrackerIdentity, UsageAggregate, UsageLedger}
  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope

  @schema_version 1
  @currency "USD"
  @scan_page 10_000
  @authority_keys [:schema_version, :aggregate_generation, :source_position, :source_generation, :price_table_revision]
  @freshness_keys [:status, :projected_position, :ledger_position]

  @type error :: :invalid_identifier | :usage_not_found | :usage_unresolvable | :usage_unavailable

  @doc """
  Returns the JSON-safe usage payload for one GitHub issue number.

  Options are seams for tests: `:scan_fun` (`UsageLedger.scan/1`),
  `:cells_snapshot_fun` (`UsageAggregate.cells_snapshot/0`) and
  `:repository_fun` (`Aiur.GitHub.Config.configured_repo/0`).
  """
  @spec fetch(term(), keyword()) :: {:ok, map()} | {:error, error()}
  def fetch(identifier, opts \\ []) do
    with {:ok, number} <- number(identifier),
         {:ok, repository} <- repository(opts),
         {:ok, source} <- cells_snapshot(opts),
         {:ok, identities} <- identities(number, repository, source, opts) do
      {:ok, scope} = Scope.explicit_ticket_set(identities)
      snapshot = GroupedScopes.project(source, scope, currency: @currency)

      if snapshot.state == :unavailable,
        do: {:error, :usage_unavailable},
        else: {:ok, payload(number, repository, source, scope, snapshot)}
    end
  end

  defp number(identifier) when is_binary(identifier) do
    if Regex.match?(~r/\A[1-9][0-9]{0,18}\z/, identifier), do: {:ok, identifier}, else: {:error, :invalid_identifier}
  end

  defp number(_identifier), do: {:error, :invalid_identifier}

  defp repository(opts) do
    case Keyword.get(opts, :repository_fun, &GitHubConfig.configured_repo/0).() do
      {:ok, {owner, name}} -> {:ok, {owner, name}}
      _missing -> {:error, :usage_unavailable}
    end
  end

  # Pages through the retained ledger by position; the store caps one page.
  defp identities(number, repository, source, opts) do
    scan = Keyword.get(opts, :scan_fun, &UsageLedger.scan/1)
    page = Keyword.get(opts, :scan_page, @scan_page)

    case collect(scan, page, 0, ticket_matcher(number, repository), %{found: %{}, first: nil}) do
      {:ok, %{found: found} = acc} when map_size(found) == 0 -> {:error, miss(acc.first, source)}
      {:ok, %{found: found}} -> {:ok, Map.values(found)}
      {:error, _reason} -> {:error, :usage_unavailable}
    end
  catch
    :exit, _reason -> {:error, :usage_unavailable}
  end

  defp collect(scan, page, after_position, matcher, acc) do
    case scan.(after: after_position, limit: page) do
      {:ok, records} when is_list(records) ->
        acc = %{acc | first: acc.first || first_position(records), found: Enum.reduce(records, acc.found, &remember(&1, matcher, &2))}

        if length(records) < page,
          do: {:ok, acc},
          else: collect(scan, page, List.last(records).position, matcher, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp first_position([%{position: position} | _rest]), do: position
  defp first_position([]), do: nil

  # Positions start at 1, so a retained head past 1 (or an empty ledger behind
  # an aggregate that folded records) means compaction retired a prefix.
  defp miss(first, %{metadata: metadata}) do
    retired? = if first, do: first > 1, else: (Map.get(metadata, :source_position) || 0) > 0
    if retired?, do: :usage_unresolvable, else: :usage_not_found
  end

  defp remember(%{envelope: %{attribution: %{tracker_identity: identity}}}, matcher, found) do
    key = TrackerIdentity.github_key(identity)
    if matcher.(key, identity), do: Map.put_new(found, key, identity), else: found
  end

  defp remember(_record, _matcher, found), do: found

  defp ticket_matcher(number, {owner, name}) do
    owner = String.downcase(owner)
    name = String.downcase(name)

    fn
      {:github, ^owner, ^name, _provider_id}, %TrackerIdentity{identifier: ^number} -> true
      _key, _identity -> false
    end
  end

  defp cells_snapshot(opts) do
    case Keyword.get(opts, :cells_snapshot_fun, &UsageAggregate.cells_snapshot/0).() do
      %{cells: cells, metadata: metadata} = source when is_map(cells) and is_map(metadata) -> {:ok, source}
      _unavailable -> {:error, :usage_unavailable}
    end
  catch
    :exit, _reason -> {:error, :usage_unavailable}
  end

  # --- wire shape ---------------------------------------------------------

  defp payload(number, {owner, name}, source, scope, snapshot) do
    JSONSafe.normalize(%{
      schema_version: @schema_version,
      ticket: %{owner: owner, repository: name, identifier: number},
      currency: snapshot.currency,
      state: snapshot.state,
      authority: Map.take(snapshot.authority, @authority_keys),
      freshness: Map.take(snapshot.freshness || %{}, @freshness_keys),
      totals: totals(snapshot),
      by_model: models(snapshot),
      by_provider: providers(snapshot),
      sessions: sessions(source, scope, snapshot)
    })
  end

  defp totals(snapshot) do
    %{
      tokens: snapshot.tokens,
      provider_reported: money(snapshot.provider_reported_estimate.by_currency),
      api_equivalent: %{
        amount: money(snapshot.api_equivalent_estimate.rollup),
        coverage: coverage(snapshot.api_equivalent_estimate.coverage)
      }
    }
  end

  defp models(snapshot) do
    Enum.map(snapshot.contributors.by_model, &Map.put(measure(&1), :model, &1.key))
  end

  defp providers(snapshot) do
    Enum.map(snapshot.contributors.by_provider_route, fn entry ->
      entry
      |> measure()
      |> Map.merge(%{provider: entry.key.provider, upstream_provider: entry.key.upstream_provider})
    end)
  end

  # A session is one Aiur run (`run_id`): the aggregate retains the run, not the
  # harness session id, so per-session model and provider rows re-project the
  # same ticket scope over that run's cells.
  defp sessions(source, scope, snapshot) do
    Enum.map(snapshot.contributors.by_run, fn %{key: run_id} = entry ->
      run_cells = Map.filter(source.cells, fn {{dims, _measure}, _value} -> dims.run_id == run_id end)
      run_snapshot = GroupedScopes.project(%{source | cells: run_cells}, scope, currency: @currency)

      entry
      |> measure()
      |> Map.merge(%{run_id: run_id, by_model: models(run_snapshot), by_provider: providers(run_snapshot)})
    end)
  end

  defp measure(entry) do
    %{
      tokens: entry.tokens,
      provider_reported: money(entry.provider_reported),
      api_equivalent: %{amount: money(entry.api_equivalent.amount), coverage: coverage(entry.api_equivalent.coverage)}
    }
  end

  defp coverage(coverage), do: Map.take(coverage, [:status, :known, :unknown, :reasons])

  # Exact decimal strings: a float would round money a consumer must reconcile.
  defp money(amounts), do: Map.new(amounts, fn {currency, amount} -> {currency, Decimal.to_string(amount, :normal)} end)
end
