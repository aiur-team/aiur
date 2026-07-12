defmodule Aiur.DecisionApi do
  @moduledoc """
  Machine-facing application facade for canonical Decision operations.

  This module does not persist a parallel API representation. It reads the
  current `Aiur.DecisionStore` projection, encodes it through
  `Aiur.DecisionProjection`, and adds a current fail-closed supervisor policy
  evaluation. Mutations remain thin delegates to their canonical store
  services.
  """

  alias Aiur.{
    Config,
    Decision,
    DecisionAnswer,
    DecisionAuthority,
    DecisionDelegation,
    DecisionProjection,
    DecisionRevision,
    DecisionStore
  }

  @default_limit 50
  @maximum_limit 200
  @maximum_offset 1_000_000
  @decision_id_max 256
  @list_fields ~w(authority blocking kind limit offset ticket)
  @supervisor_actor %{kind: :supervisor, id: "supervising-agent"}

  @type read_error ::
          :not_found
          | :store_unavailable
          | {:invalid_decision_id, atom()}
          | {:invalid_list, term()}

  @doc "Returns a deterministic, bounded list of canonical Decision projections."
  @spec list(map(), keyword()) :: {:ok, map()} | {:error, read_error()}
  def list(params \\ %{}, opts \\ [])

  def list(params, opts) when is_map(params) and is_list(opts) do
    with {:ok, filters} <- normalize_list_params(params),
         {:ok, decisions} <- read_list(Keyword.get(opts, :store, DecisionStore)) do
      policy = policy(opts)

      filtered =
        decisions
        |> Enum.filter(&matches_filters?(&1, filters))
        |> Enum.sort_by(&sort_key/1)

      total = length(filtered)
      page = filtered |> Enum.drop(filters.offset) |> Enum.take(filters.limit)
      next_offset = next_offset(filters.offset, length(page), total)

      {:ok,
       %{
         "decisions" => Enum.map(page, &encode_decision(&1, policy)),
         "pagination" => %{
           "limit" => filters.limit,
           "offset" => filters.offset,
           "next_offset" => next_offset,
           "total" => total
         }
       }}
    end
  end

  def list(_params, opts) when is_list(opts), do: {:error, {:invalid_list, {:params, :invalid_type}}}

  @doc "Returns one canonical Decision projection by ID."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, read_error()}
  def get(decision_id, opts \\ []) when is_list(opts) do
    with {:ok, normalized_id} <- normalize_decision_id(decision_id),
         {:ok, decision} <- read_one(normalized_id, Keyword.get(opts, :store, DecisionStore)) do
      {:ok, encode_decision(decision, policy(opts))}
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
         {:ok, decision} <- read_one(normalized_id, store),
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
         {:ok, decision} <- read_one(normalized_id, store),
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

  defp normalize_list_params(params) do
    with {:ok, normalized} <- normalize_param_keys(params),
         {:ok, limit} <- bounded_integer(normalized["limit"], @default_limit, 1, @maximum_limit, :limit),
         {:ok, offset} <- bounded_integer(normalized["offset"], 0, 0, @maximum_offset, :offset),
         {:ok, ticket} <- optional_string(normalized["ticket"], 200, :ticket),
         {:ok, kind} <- optional_string(normalized["kind"], 100, :kind),
         {:ok, authority} <- optional_authority(normalized["authority"]),
         {:ok, blocking} <- optional_boolean(normalized["blocking"]) do
      {:ok,
       %{
         limit: limit,
         offset: offset,
         ticket: ticket,
         kind: kind && String.downcase(kind),
         authority: authority,
         blocking: blocking
       }}
    else
      {:error, reason} -> {:error, {:invalid_list, reason}}
    end
  end

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

  defp normalize_param_keys(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      case normalize_key(raw_key) do
        {:ok, key} ->
          cond do
            key not in @list_fields -> {:halt, {:error, {:field, key, :unknown}}}
            Map.has_key?(normalized, key) -> {:halt, {:error, {:field, key, :duplicate}}}
            true -> {:cont, {:ok, Map.put(normalized, key, value)}}
          end

        :error ->
          {:halt, {:error, {:field, :invalid}}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error

  defp bounded_integer(nil, default, _minimum, _maximum, _field), do: {:ok, default}

  defp bounded_integer(value, _default, minimum, maximum, field) do
    case parse_integer(value) do
      integer when is_integer(integer) and integer >= minimum and integer <= maximum -> {:ok, integer}
      _invalid -> {:error, {field, :invalid}}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp optional_string(nil, _maximum, _field), do: {:ok, nil}

  defp optional_string(value, maximum, field) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {field, :missing}}
      String.length(trimmed) > maximum -> {:error, {field, :too_long}}
      unsafe_control_chars?(value) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, trimmed}
    end
  end

  defp optional_string(_value, _maximum, field), do: {:error, {field, :invalid_type}}

  defp optional_authority(nil), do: {:ok, nil}

  defp optional_authority(value) when is_atom(value) do
    if value in Decision.authorities(), do: {:ok, value}, else: {:error, {:authority, :invalid}}
  end

  defp optional_authority(value) when is_binary(value) do
    case Enum.find(Decision.authorities(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:authority, :invalid}}
      authority -> {:ok, authority}
    end
  end

  defp optional_authority(_value), do: {:error, {:authority, :invalid}}

  defp optional_boolean(nil), do: {:ok, nil}
  defp optional_boolean(true), do: {:ok, true}
  defp optional_boolean(false), do: {:ok, false}
  defp optional_boolean("true"), do: {:ok, true}
  defp optional_boolean("false"), do: {:ok, false}
  defp optional_boolean(_value), do: {:error, {:blocking, :invalid}}

  defp matches_filters?(%Decision{} = decision, filters) do
    optional_match(filters.ticket, decision.ticket.identifier) and
      optional_match(filters.authority, decision.authority) and
      optional_match(filters.blocking, decision.blocking) and
      optional_kind_match(filters.kind, decision.kind)
  end

  defp optional_match(nil, _actual), do: true
  defp optional_match(expected, actual), do: expected == actual

  defp optional_kind_match(nil, _actual), do: true
  defp optional_kind_match(_expected, nil), do: false
  defp optional_kind_match(expected, actual), do: expected == String.downcase(String.trim(actual))

  defp sort_key(%Decision{} = decision) do
    {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end

  defp next_offset(offset, page_size, total) when offset + page_size < total, do: offset + page_size
  defp next_offset(_offset, _page_size, _total), do: nil

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

  defp read_list(store) do
    case safe_store_call(fn -> DecisionStore.list(store) end) do
      decisions when is_list(decisions) -> {:ok, decisions}
      _invalid -> {:error, :store_unavailable}
    end
  end

  defp read_one(decision_id, store) do
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
