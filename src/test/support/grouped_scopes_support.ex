defmodule Aiur.TestSupport.GroupedScopes do
  @moduledoc false

  # Builds DASH-030 query inputs (`%{cells: ..., metadata: ...}`) from DASH-024
  # replay records, reusing the shared aggregate/ledger factories so the cells a
  # test prices are exactly the cells the projection would fold in production.

  alias Aiur.TestSupport.UsageAggregate, as: Aggregate
  alias Aiur.TrackerIdentity
  alias Aiur.UsageAggregate.Projection
  alias Aiur.UsageEnvelope.ExactMoney

  # The claude relationship revision the standard price catalog is keyed by.
  @claude_price_relationship "claude-remote-control-2026-07"
  @codex_price_relationship "codex-app-server-2026-07"

  @spec identity(integer()) :: TrackerIdentity.t()
  def identity(number) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "node-#{number}",
      database_id: number,
      identifier: Integer.to_string(number),
      reason: nil
    }
  end

  @doc "A joinable identity in a different repository for collision fixtures."
  @spec identity(String.t(), String.t(), integer()) :: TrackerIdentity.t()
  def identity(owner, repository, number) do
    %{identity(number) | owner: owner, repository: repository}
  end

  def attribution(run_id, identity) do
    %{
      run_id: run_id,
      tracker_identity: identity,
      attempt_id: "attempt-1",
      session_id: "session-1",
      thread_id: "thread-1",
      turn_id: "turn-1",
      request_id: "request-1"
    }
  end

  @doc "Builds an aggregate source snapshot from ordered replay records."
  def source(records, metadata_overrides \\ %{}) do
    projection = Projection.apply_records(Projection.new(), records)
    %{cells: projection.cells, metadata: metadata(projection, metadata_overrides)}
  end

  @doc """
  Builds a source from raw `{dims, measure, value}` cells.

  Lets a test exercise identity dimensions the envelope factory rejects (an
  unknown/`nil` account generation, an `:unknown` backend) that the aggregate
  can legitimately carry.
  """
  def raw_source(cells_list, metadata_overrides \\ %{}) do
    cells = Map.new(cells_list, fn {dims, measure, value} -> {{dims, measure}, value} end)
    count = length(cells_list)

    metadata =
      Map.merge(
        %{
          generation: count,
          source_position: count,
          source_generation: 0,
          health: :healthy,
          freshness: %{status: :fresh, projected_position: count, ledger_position: count, recovery: :clean},
          coverage: %{folded_records: count, partial_records: 0, reasons: MapSet.new()},
          source_coverage: %{lower: 1, upper: max(count, 1), status: :full}
        },
        metadata_overrides
      )

    %{cells: cells, metadata: metadata}
  end

  @doc "A full aggregate cell dims map, overridable per key."
  def dims(overrides \\ %{}) do
    Map.merge(
      %{
        provider: :claude,
        run_id: "run-1115",
        ticket: {:github, "its-everdred", "aiur", "node-1115"},
        attempt_id: "attempt-1",
        account_generation: "generation-c",
        backend: :remote_control,
        agent_family: :claude,
        resolved_model: "claude-sonnet-4-6",
        auth_mode: :api_key,
        pricing_date: ~D[2026-07-15],
        relationship_revision: @claude_price_relationship
      },
      overrides
    )
  end

  def metadata(projection, overrides \\ %{}) do
    Map.merge(
      %{
        generation: projection.generation,
        source_position: projection.source_position,
        source_generation: projection.source_generation,
        health: :healthy,
        freshness: %{
          status: :fresh,
          projected_position: projection.source_position,
          ledger_position: projection.source_position,
          recovery: :clean
        },
        coverage: projection.coverage,
        source_coverage: %{lower: 1, upper: max(projection.source_position, 1), status: :full}
      },
      overrides
    )
  end

  @doc "A codex replay record. API-equivalent is unknown (context tier unretained)."
  def codex_record(position, opts \\ []) do
    env =
      Aggregate.envelope(%{
        attribution: attribution(run_id(opts), ticket_identity(opts)),
        resolved_model: Keyword.get(opts, :model, "gpt-5.6-terra"),
        requested_model: Keyword.get(opts, :model, "gpt-5.6-terra"),
        auth_mode: Keyword.get(opts, :auth_mode, :chatgpt),
        relationship_revision: Keyword.get(opts, :relationship_revision, @codex_price_relationship),
        account_generation: account_generation(:codex, :app_server, generation(opts, "generation-a"))
      })

    Aggregate.record(position, env, delta(opts))
  end

  @doc "A claude replay record priced against the standard catalog by default."
  def claude_record(position, opts \\ []) do
    env =
      Aggregate.claude_envelope(%{
        attribution: attribution(run_id(opts), ticket_identity(opts)),
        resolved_model: Keyword.get(opts, :model, "claude-sonnet-4-6"),
        requested_model: Keyword.get(opts, :model, "claude-sonnet-4-6"),
        auth_mode: Keyword.get(opts, :auth_mode, :api_key),
        relationship_revision: Keyword.get(opts, :relationship_revision, @claude_price_relationship),
        account_generation: account_generation(:claude, :remote_control, generation(opts, "generation-c"))
      })

    Aggregate.record(position, env, delta(opts))
  end

  @doc "A delta-basis ExactMoney in an arbitrary currency for mixed-currency fixtures."
  def money(amount, currency \\ "USD") do
    {:ok, money} =
      ExactMoney.decode(%{
        amount: amount,
        currency: currency,
        unit: :major,
        measurement_kind: :delta,
        counter_scope: :thread,
        source: "provider-cost",
        source_version: "2026-07"
      })

    money
  end

  defp run_id(opts), do: Keyword.get(opts, :run_id, "run-1115")

  defp generation(opts, default), do: Keyword.get(opts, :generation, default)

  defp ticket_identity(opts) do
    case Keyword.get(opts, :ticket, :default) do
      :default -> identity(1115)
      nil -> nil
      %TrackerIdentity{} = identity -> identity
      number when is_integer(number) -> identity(number)
    end
  end

  defp account_generation(provider, backend, generation) do
    %{provider: provider, backend: backend, generation: generation, freshness: :current, health: :healthy, reason: nil}
  end

  defp delta(opts) do
    base = %{tokens: Keyword.get(opts, :tokens, %{input: 10})}

    case Keyword.get(opts, :cost) do
      nil -> base
      cost -> Map.put(base, :cost, cost)
    end
  end
end
