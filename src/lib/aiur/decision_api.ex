defmodule Aiur.DecisionApi do
  @moduledoc """
  Machine-facing application facade for canonical Decision operations.

  This module does not persist a parallel API representation. It reads the
  retained `Aiur.DecisionQuery` projection, encodes it through
  `Aiur.DecisionProjection`, and adds a current fail-closed supervisor policy
  evaluation. Mutations remain thin delegates to their canonical store services.
  """

  alias Aiur.{
    Config,
    Decision,
    DecisionAnswer,
    DecisionApi.LegacyPagination,
    DecisionAuthority,
    DecisionDelegation,
    DecisionProjection,
    DecisionQuery,
    DecisionRevision,
    DecisionStore
  }

  @decision_id_max 256
  @supervisor_actor %{kind: :supervisor, id: "supervising-agent"}

  @type read_error ::
          :not_found
          | :store_unavailable
          | {:indeterminate, map()}
          | {:invalid_decision_id, atom()}
          | {:invalid_list, term()}

  @doc "Returns bounded retained Decision projections with v1 offset compatibility."
  @spec list(map(), keyword()) :: {:ok, map()} | {:error, read_error()}
  def list(params \\ %{}, opts \\ [])

  def list(params, opts) when is_map(params) and is_list(opts) do
    with {:ok, page} <- retained_list(params, Keyword.get(opts, :store, DecisionStore)) do
      {:ok, encode_retained_page(page, policy(opts))}
    end
  end

  def list(_params, opts) when is_list(opts), do: {:error, {:invalid_list, {:params, :invalid_type}}}

  @doc "Returns one canonical Decision projection by ID."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, read_error()}
  def get(decision_id, opts \\ []) when is_list(opts) do
    case DecisionQuery.get(decision_id, store: Keyword.get(opts, :store, DecisionStore)) do
      {:ok, %{decision: decision}} -> {:ok, encode_decision(decision, policy(opts))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Appends one constrained supervisor enrichment through DecisionStore."
  @spec enrich(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def enrich(decision_id, payload, opts \\ [])

  def enrich(decision_id, payload, opts) when is_map(payload) and is_list(opts) do
    with {:ok, normalized_id} <- normalize_decision_id(decision_id),
         {:ok, expected_version, patch} <- split_enrichment_payload(payload),
         {:ok, actor} <- trusted_supervisor_actor(opts),
         {:ok, result} <-
           write_enrichment(
             normalized_id,
             patch,
             enrichment_opts(opts, actor, expected_version),
             Keyword.get(opts, :store, DecisionStore)
           ) do
      {:ok,
       %{
         "status" => Atom.to_string(result.status),
         "decision" => encode_decision(result.decision, policy(opts))
       }}
    end
  end

  def enrich(_decision_id, _payload, opts) when is_list(opts),
    do: {:error, {:invalid_enrichment, {:payload, :invalid_type}}}

  @doc "Authorizes and delegates one supervisor answer to OCC-3's canonical outbox."
  @spec decide(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(decision_id, payload, opts \\ [])

  def decide(decision_id, payload, opts) when is_map(payload) and is_list(opts) do
    current_policy = policy(opts)
    store = Keyword.get(opts, :store, DecisionStore)

    with {:ok, normalized_id} <- normalize_decision_id(decision_id),
         {:ok, actor} <- trusted_decision_actor(opts),
         {:ok, decision} <- read_current(normalized_id, store),
         {:ok, delegation} <- DecisionDelegation.normalize(decision, payload, current_policy),
         {:ok, result} <-
           write_answer(
             normalized_id,
             delegation.answer_payload,
             answer_opts(opts, actor, delegation.basis),
             store
           ) do
      {:ok,
       %{
         "status" => Atom.to_string(result.status),
         "decision" => encode_decision(result.decision, current_policy),
         "action" => DecisionAnswer.to_json_safe(result.action),
         "dispatch_status" => Atom.to_string(result.dispatch_status)
       }}
    end
  end

  def decide(_decision_id, _payload, opts) when is_list(opts),
    do: {:error, {:delegation_invalid, {:payload, :invalid_type}}}

  @doc "Authorizes a supervisor revision and delegates all semantics to OCC-8."
  @spec revise(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def revise(decision_id, payload, opts \\ [])

  def revise(decision_id, payload, opts) when is_map(payload) and is_list(opts) do
    current_policy = policy(opts)
    store = Keyword.get(opts, :store, DecisionStore)

    with {:ok, normalized_id} <- normalize_decision_id(decision_id),
         {:ok, actor} <- trusted_revision_actor(opts),
         {:ok, decision} <- read_current(normalized_id, store),
         {:ok, delegation} <- DecisionDelegation.normalize_revision(decision, payload, current_policy),
         {:ok, result} <-
           write_revision(
             normalized_id,
             delegation.answer_payload,
             revision_opts(opts, actor, delegation.basis, decision.authority),
             store
           ) do
      {:ok,
       %{
         "status" => Atom.to_string(result.status),
         "decision" => encode_decision(result.decision, current_policy),
         "action" => DecisionRevision.to_json_safe(result.action, &DecisionAnswer.to_json_safe/1),
         "revision_result" => Atom.to_string(result.revision_result),
         "dispatch_status" => Atom.to_string(result.dispatch_status)
       }}
    end
  end

  def revise(_decision_id, _payload, opts) when is_list(opts),
    do: {:error, {:revision_invalid, {:payload, :invalid_type}}}

  defp split_enrichment_payload(payload) do
    string_value = Map.fetch(payload, "expected_version")
    atom_value = Map.fetch(payload, :expected_version)

    case {string_value, atom_value} do
      {{:ok, _value}, {:ok, _duplicate}} ->
        {:error, {:invalid_enrichment, {:expected_version, :duplicate}}}

      {{:ok, version}, :error} when is_integer(version) and version > 0 ->
        {:ok, version, Map.delete(payload, "expected_version")}

      {:error, {:ok, version}} when is_integer(version) and version > 0 ->
        {:ok, version, Map.delete(payload, :expected_version)}

      _missing_or_invalid ->
        {:error, {:invalid_enrichment, {:expected_version, :invalid}}}
    end
  end

  defp trusted_supervisor_actor(opts) do
    case Keyword.get(opts, :actor) do
      @supervisor_actor = actor -> {:ok, actor}
      _untrusted -> {:error, {:invalid_enrichment, {:actor, :untrusted}}}
    end
  end

  defp trusted_decision_actor(opts) do
    case Keyword.get(opts, :actor) do
      @supervisor_actor = actor -> {:ok, actor}
      _untrusted -> {:error, {:delegation_invalid, {:actor, :untrusted}}}
    end
  end

  defp trusted_revision_actor(opts) do
    case Keyword.get(opts, :actor) do
      @supervisor_actor = actor -> {:ok, actor}
      _untrusted -> {:error, {:revision_invalid, {:actor, :untrusted}}}
    end
  end

  defp revision_opts(opts, actor, basis, authority) do
    [actor: actor, supervisor_basis: basis, authority: authority]
    |> maybe_put_option(:now, opts)
  end

  defp enrichment_opts(opts, actor, expected_version) do
    [actor: actor, expected_version: expected_version]
    |> maybe_put_option(:now, opts)
    |> maybe_put_option(:safe_roots, opts)
  end

  defp answer_opts(opts, actor, basis) do
    [actor: actor, supervisor_basis: basis]
    |> maybe_put_option(:now, opts)
  end

  defp maybe_put_option(target, key, source) do
    if Keyword.has_key?(source, key), do: Keyword.put(target, key, Keyword.get(source, key)), else: target
  end

  defp normalize_decision_id(decision_id) when is_binary(decision_id) do
    trimmed = String.trim(decision_id)

    cond do
      trimmed == "" -> {:error, {:invalid_decision_id, :missing}}
      String.length(trimmed) > @decision_id_max -> {:error, {:invalid_decision_id, :too_long}}
      trimmed != decision_id or unsafe_control_chars?(decision_id) -> {:error, {:invalid_decision_id, :malformed}}
      true -> {:ok, decision_id}
    end
  rescue
    _invalid -> {:error, {:invalid_decision_id, :malformed}}
  end

  defp normalize_decision_id(_decision_id), do: {:error, {:invalid_decision_id, :invalid_type}}

  defp retained_list(params, store) do
    case LegacyPagination.list(params, store) do
      {:ok, %{health: %{status: :unavailable}}} -> {:error, :store_unavailable}
      {:ok, page} -> {:ok, page}
      {:error, {:invalid_query, reason}} -> {:error, {:invalid_list, reason}}
    end
  end

  defp read_current(decision_id, store) do
    case safe_store_call(fn -> DecisionStore.get(decision_id, store) end) do
      {:ok, %Decision{} = decision} -> {:ok, decision}
      {:error, :not_found} -> {:error, :not_found}
      _invalid -> {:error, :store_unavailable}
    end
  end

  defp write_enrichment(decision_id, patch, opts, store) do
    case safe_store_call(fn -> DecisionStore.enrich(decision_id, patch, opts, store) end) do
      {:ok, %{status: status, decision: %Decision{} = decision}}
      when status in [:accepted, :duplicate] ->
        {:ok, %{status: status, decision: decision}}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :store_unavailable}
    end
  end

  defp write_answer(decision_id, payload, opts, store) do
    case safe_store_call(fn -> DecisionStore.answer(decision_id, payload, opts, store) end) do
      {:ok,
       %{
         status: status,
         decision: %Decision{} = decision,
         action: %DecisionAnswer{} = action,
         dispatch_status: dispatch_status
       }}
      when status in [:accepted, :duplicate] and is_atom(dispatch_status) ->
        {:ok,
         %{
           status: status,
           decision: decision,
           action: action,
           dispatch_status: dispatch_status
         }}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :store_unavailable}
    end
  end

  defp write_revision(decision_id, payload, opts, store) do
    case safe_store_call(fn -> DecisionStore.revise(decision_id, payload, opts, store) end) do
      {:ok,
       %{
         status: status,
         decision: %Decision{} = decision,
         action: %DecisionRevision{} = action,
         revision_result: revision_result,
         dispatch_status: dispatch_status
       }}
      when status in [:accepted, :duplicate] and is_atom(revision_result) and is_atom(dispatch_status) ->
        {:ok,
         %{
           status: status,
           decision: decision,
           action: action,
           revision_result: revision_result,
           dispatch_status: dispatch_status
         }}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :store_unavailable}
    end
  end

  defp safe_store_call(fun) do
    fun.()
  rescue
    _error -> :store_unavailable
  catch
    :exit, _reason -> :store_unavailable
  end

  defp policy(opts) do
    case Keyword.fetch(opts, :policy) do
      {:ok, policy} -> policy
      :error -> configured_policy()
    end
  end

  defp configured_policy do
    Config.supervisor_decision_policy()
  rescue
    _error -> %{}
  catch
    :exit, _reason -> %{}
  end

  defp encode_retained_page(page, policy) do
    %{
      "decisions" => Enum.map(page.decisions, &encode_decision(&1, policy)),
      "scope" => %{
        "kind" => Atom.to_string(page.scope.kind),
        "label" => page.scope.label
      },
      "health" => %{
        "status" => Atom.to_string(page.health.status),
        "partial" => page.health.partial?,
        "reason" => atom_or_nil(page.health.reason),
        "label" => page.health.label
      },
      "partial_results" => page.partial_results?,
      "partial_reason" => atom_or_nil(page.partial_reason),
      "pagination" => %{
        "limit" => page.pagination.limit,
        "offset" => Map.get(page.pagination, :offset),
        "next_offset" => Map.get(page.pagination, :next_offset),
        "cursor" => page.pagination.cursor,
        "next_cursor" => page.pagination.next_cursor,
        "total" => page.pagination.total,
        "partial_reason" => atom_or_nil(page.pagination.partial_reason),
        "label" => page.pagination.label
      },
      "filters" => Map.new(page.filters, fn {key, value} -> {Atom.to_string(key), atom_or_nil(value)} end),
      "counts" => Map.new(page.counts, fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_nil(value), do: value

  defp encode_decision(%Decision{} = decision, policy) do
    evaluation = DecisionAuthority.evaluate(decision, policy)

    decision
    |> DecisionProjection.to_json_safe()
    |> Map.put("supervisor_policy", %{
      "allowed" => evaluation.allowed,
      "checks" => Map.new(evaluation.checks, fn {key, value} -> {Atom.to_string(key), value} end),
      "configured_non_reversible_opt_in" => evaluation.policy.allow_non_reversible,
      "reasons" => Enum.map(evaluation.reasons, &Atom.to_string/1)
    })
  end

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F))
  end
end
