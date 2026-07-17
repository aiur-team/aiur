defmodule Aiur.CurrentRunOutcomeSnapshot.SourceState do
  @moduledoc false

  alias Aiur.CurrentRunProjection.Value

  @spec evaluate(map(), map(), map(), term()) :: map()
  def evaluate(run, membership, recent_merges, repository) do
    membership_freshness = membership |> Value.get(:freshness) |> Value.freshness()

    facts = %{
      run_valid?: valid_run?(run),
      run_matches?: Value.get(membership, :run_id) == Value.get(run, :id),
      repository_available?: match?({:ok, _repository}, repository),
      membership_health: membership |> Value.get(:health) |> Value.health(),
      membership_truncated?: Value.get(membership, :truncated?, false) == true,
      merge_health: recent_merges |> Value.get(:health) |> merge_health(),
      reconciliation: recent_merges |> Value.get(:reconciliation) |> Value.get(:status, :unknown),
      membership_freshness: membership_freshness
    }

    unavailable? = unavailable?(facts)
    partial? = partial?(facts)

    %{
      unavailable?: unavailable?,
      partial?: partial?,
      freshness: projection_freshness(facts, unavailable?, partial?),
      reasons: reasons(facts)
    }
  end

  @spec normalize_repository(term()) :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def normalize_repository({:ok, repository}), do: normalize_repository(repository)

  def normalize_repository({owner, repository}) when is_binary(owner) and is_binary(repository) do
    owner = String.trim(owner)
    repository = String.trim(repository)

    if owner != "" and repository != "" and not String.contains?(owner, "/") and
         not String.contains?(repository, "/") do
      {:ok, {owner, repository}}
    else
      {:error, :invalid_configured_repository}
    end
  end

  def normalize_repository({:error, reason}), do: {:error, reason}
  def normalize_repository(_repository), do: {:error, :invalid_configured_repository}

  @spec normalize_repository_name(term()) :: {:ok, {String.t(), String.t()}} | {:error, atom()}
  def normalize_repository_name(value) when is_binary(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [owner, repository] -> normalize_repository({owner, repository})
      _parts -> {:error, :invalid_repository}
    end
  end

  def normalize_repository_name(_value), do: {:error, :invalid_repository}

  @spec same_repository?({String.t(), String.t()}, {String.t(), String.t()}) :: boolean()
  def same_repository?({left_owner, left_repo}, {right_owner, right_repo}) do
    String.downcase(left_owner) == String.downcase(right_owner) and
      String.downcase(left_repo) == String.downcase(right_repo)
  end

  @spec add_partial(map(), atom()) :: map()
  def add_partial(state, reason), do: %{state | partial?: true, reasons: Enum.uniq(state.reasons ++ [reason])}

  @spec public_state(map(), [map()]) :: atom()
  def public_state(%{unavailable?: true}, _outcomes), do: :unavailable
  def public_state(%{freshness: :stale}, _outcomes), do: :stale
  def public_state(%{partial?: true}, _outcomes), do: :partial
  def public_state(_source_state, []), do: :healthy_empty
  def public_state(_source_state, _outcomes), do: :healthy

  @spec completeness(map()) :: atom()
  def completeness(%{unavailable?: true}), do: :unavailable
  def completeness(%{partial?: true}), do: :partial
  def completeness(%{freshness: freshness}) when freshness != :fresh, do: :partial
  def completeness(_source_state), do: :complete

  @spec health(atom()) :: :healthy | :partial | :unavailable
  def health(:unavailable), do: :unavailable
  def health(state) when state in [:partial, :stale], do: :partial
  def health(_state), do: :healthy

  @spec public_run(map()) :: map()
  def public_run(run) do
    %{id: Value.get(run, :id), started_at: Value.get(run, :started_at), observed_at: Value.get(run, :observed_at)}
  end

  @spec repository_name({String.t(), String.t()}) :: String.t()
  def repository_name({owner, repository}), do: "#{owner}/#{repository}"

  @spec configured_repository_name({:ok, {String.t(), String.t()}} | {:error, term()}) ::
          String.t() | nil
  def configured_repository_name({:ok, repository}), do: repository_name(repository)
  def configured_repository_name({:error, _reason}), do: nil

  @spec provenance(map(), map(), map()) :: map()
  def provenance(membership, recent_merges, source_state) do
    %{
      run_generation: nil,
      membership_generation: Value.get(membership, :generation),
      membership_health: membership |> Value.get(:health) |> Value.health(),
      membership_freshness: source_state.freshness,
      merge_generation: Value.get(recent_merges, :generation),
      merge_health: recent_merges |> Value.get(:health) |> merge_health(),
      configured_repository_generation: nil,
      reconciliation: recent_merges |> Value.get(:reconciliation) |> safe_reconciliation()
    }
  end

  defp unavailable?(facts) do
    not facts.run_valid? or not facts.run_matches? or not facts.repository_available? or
      facts.membership_health == :unavailable or facts.merge_health == :unavailable
  end

  defp partial?(facts) do
    facts.membership_health == :degraded or facts.membership_truncated? or
      facts.merge_health == :degraded or facts.reconciliation != :complete or
      facts.membership_freshness != :fresh
  end

  defp projection_freshness(_facts, true, _partial?), do: :unavailable
  defp projection_freshness(%{membership_freshness: :stale}, false, _partial?), do: :stale
  defp projection_freshness(%{membership_freshness: :unknown}, false, _partial?), do: :unknown
  defp projection_freshness(%{membership_freshness: :unavailable}, false, _partial?), do: :unavailable
  defp projection_freshness(%{membership_freshness: :partial}, false, _partial?), do: :partial
  defp projection_freshness(_facts, false, true), do: :partial
  defp projection_freshness(_facts, false, false), do: :fresh

  defp reasons(facts) do
    []
    |> maybe_reason(not facts.run_valid?, :invalid_run_window)
    |> maybe_reason(facts.run_valid? and not facts.run_matches?, :run_membership_mismatch)
    |> maybe_reason(not facts.repository_available?, :configured_repository_unavailable)
    |> maybe_reason(facts.membership_health == :unavailable, :membership_unavailable)
    |> maybe_reason(facts.merge_health == :unavailable, :merge_source_unavailable)
    |> maybe_reason(facts.membership_health == :degraded, :membership_degraded)
    |> maybe_reason(facts.membership_truncated?, :membership_truncated)
    |> maybe_reason(facts.merge_health == :degraded, :merge_source_degraded)
    |> maybe_reason(facts.reconciliation != :complete, :reconciliation_incomplete)
    |> membership_freshness_reason(facts.membership_freshness)
  end

  defp membership_freshness_reason(reasons, :fresh), do: reasons
  defp membership_freshness_reason(reasons, :stale), do: reasons ++ [:membership_stale]
  defp membership_freshness_reason(reasons, :unknown), do: reasons ++ [:membership_freshness_unknown]
  defp membership_freshness_reason(reasons, :unavailable), do: reasons ++ [:membership_freshness_unavailable]
  defp membership_freshness_reason(reasons, :partial), do: reasons ++ [:membership_freshness_partial]
  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons
  defp merge_health(:writable), do: :healthy
  defp merge_health(status), do: Value.health(status)

  defp valid_run?(run) do
    id = Value.get(run, :id)
    started_at = Value.get(run, :started_at)
    observed_at = Value.get(run, :observed_at)

    Value.get(run, :valid?, true) == true and is_binary(id) and String.trim(id) != "" and
      is_struct(started_at, DateTime) and is_struct(observed_at, DateTime) and
      DateTime.compare(observed_at, started_at) != :lt
  end

  defp safe_reconciliation(value) when is_map(value) do
    %{status: Value.get(value, :status, :unknown), partial?: Value.get(value, :partial?), pages_fetched: Value.get(value, :pages_fetched, 0)}
  end

  defp safe_reconciliation(_value), do: %{status: :unknown, partial?: nil, pages_fetched: 0}
end
