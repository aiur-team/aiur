defmodule Aiur.Commands.HostApi do
  @moduledoc """
  Permission-scoped Command reads and answers for an embedding host application.

  Every operation is bound to the ticket set and label scope taken from a
  verified `Aiur.Commands.Scope`, never from request content:

    * reads reuse the canonical retained projection (`Aiur.DecisionQuery` plus
      `Aiur.DecisionApi.PublicProjection`), so no second Command projection
      exists;
    * a Command is in scope when its ticket is in the grant's explicit ticket
      set or its ticket carries one of the grant's labels; label membership
      comes from the tracker's observed open-issue labels and fails closed;
    * an out-of-scope Command is reported as `:not_found`, whether or not the
      caller guessed a real identifier, so it is non-enumerable;
    * answers go through `Aiur.Commands.Answering`, which keeps optimistic
      version checks, idempotency, replacement precedence and audit
      attribution intact.

  The returned maps are the documented component contract from
  `Aiur.Commands.ComponentState`.
  """

  alias Aiur.Commands.{Answering, ComponentState, Scope}
  alias Aiur.DecisionApi.PublicProjection
  alias Aiur.DecisionQuery
  alias Aiur.JSONSafe

  @default_limit 25
  @maximum_limit 100
  @maximum_answer_key_bytes 200
  @label_observation_max_age_ms 120_000

  @type scope :: Scope.t()
  @type read_error :: :not_found | :store_unavailable | {:invalid_query, term()}
  @type answer_error ::
          :not_found
          | :store_unavailable
          | {:invalid_answer, term()}
          | {:conflict, term()}

  @doc "Lists the scoped Commands the grant may see."
  @spec list(scope(), map(), keyword()) :: {:ok, map()} | {:error, read_error()}
  def list(scope, params \\ %{}, opts \\ [])

  def list(%{ticket_set: _ticket_set} = scope, params, opts) when is_map(params) do
    params = restrict(params, "limit", @maximum_limit)

    case DecisionQuery.list_scoped(params, authorized_tickets(scope, opts), store: store(opts)) do
      {:ok, page} ->
        commands = Enum.map(page.decisions, &component/1)

        {:ok,
         %{
           "commands" => commands,
           "count" => length(commands),
           "pagination" => pagination(page),
           "scope" => Scope.to_public(scope),
           "health" => health(page)
         }}

      {:error, {:invalid_query, _} = reason} ->
        {:error, reason}
    end
  end

  def list(_scope, _params, _opts), do: {:error, {:invalid_query, :params}}

  @doc "Shows one scoped Command; an out-of-scope Command is `:not_found`."
  @spec show(scope(), String.t(), keyword()) :: {:ok, map()} | {:error, read_error()}
  def show(scope, decision_id, opts \\ [])

  def show(%{ticket_set: _ticket_set} = scope, decision_id, opts) do
    with {:ok, decision} <- scoped_decision(authorized_tickets(scope, opts), decision_id, opts) do
      {:ok, %{"command" => component(decision), "scope" => Scope.to_public(scope)}}
    end
  end

  def show(_scope, _decision_id, _opts), do: {:error, :not_found}

  @doc """
  Answers, supersedes or overrides one scoped Command as its authenticated user.

  `payload` accepts `idempotency_key`, `expected_version`, one of `option_id` /
  `custom_response` / `question_answers`, an optional `rationale`, and
  `replace: true` to replace an answer that already exists.
  """
  @spec answer(scope(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, answer_error()}
  def answer(scope, decision_id, payload, opts \\ [])

  def answer(%{subject: subject} = scope, decision_id, payload, opts) when is_map(payload) do
    with {:ok, decision} <- scoped_decision(authorized_tickets(scope, opts), decision_id, opts),
         {:ok, answer_payload} <- normalize_answer(payload),
         operation <- operation(payload) do
      outcome =
        apply(Answering, operation, [
          decision.decision_id,
          strip_control_keys(answer_payload),
          [
            actor: %{kind: :operator, id: subject},
            actor_source: :host_api,
            client: %{surface: :api},
            store: store(opts)
          ]
        ])

      {:ok, %{"command" => ComponentState.from_outcome(outcome, decision_id: decision.decision_id), "scope" => Scope.to_public(scope)}}
    end
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  def answer(_scope, _decision_id, _payload, _opts), do: {:error, {:invalid_answer, :payload}}

  @doc "Renders one canonical Decision as the documented component map."
  @spec component(Aiur.Decision.t()) :: ComponentState.t()
  def component(decision) do
    decision
    |> PublicProjection.encode()
    |> JSONSafe.normalize()
    |> ComponentState.from_projection()
  end

  @doc """
  The ticket identifiers a grant may read and answer.

  The explicit ticket set is always authorized. A label scope adds the tickets
  currently observed to carry one of the grant's labels, so a ticket added to
  the game later falls into scope without re-minting. When the tracker has no
  usable label observation, the label scope authorizes nothing: it fails closed
  rather than widening to every ticket.
  """
  @spec authorized_tickets(Scope.t(), keyword()) :: MapSet.t(String.t())
  def authorized_tickets(%{ticket_set: ticket_set} = scope, opts) do
    MapSet.union(ticket_set, label_tickets(scope, opts))
  end

  defp label_tickets(%{label_set: %MapSet{} = labels}, opts) do
    if MapSet.size(labels) == 0 do
      MapSet.new()
    else
      labels |> labelled_tickets(observe_labels(opts))
    end
  end

  defp label_tickets(_scope, _opts), do: MapSet.new()

  defp observe_labels(opts) do
    fun = Keyword.get(opts, :labels_fun, fn -> Aiur.Tracker.open_issue_labels(@label_observation_max_age_ms) end)

    case fun.() do
      {:ok, observed, _observed_at} when is_map(observed) -> observed
      _unavailable -> %{}
    end
  rescue
    _error -> %{}
  catch
    :exit, _reason -> %{}
  end

  defp labelled_tickets(labels, observed) when is_map(observed) do
    Enum.reduce(observed, MapSet.new(), fn {identifier, observation}, acc ->
      ticket_labels =
        observation
        |> labels_of()
        |> Enum.map(&String.downcase/1)

      if Enum.any?(ticket_labels, &MapSet.member?(labels, &1)) do
        MapSet.put(acc, identifier |> to_string() |> String.downcase())
      else
        acc
      end
    end)
  end

  defp labelled_tickets(_labels, _observed), do: MapSet.new()

  defp labels_of(%{} = observation) when is_map(observation) do
    case Map.get(observation, :labels) || Map.get(observation, "labels") do
      labels when is_list(labels) -> Enum.filter(labels, &is_binary/1)
      _missing -> []
    end
  end

  defp labels_of(_observation), do: []

  defp scoped_decision(ticket_set, decision_id, opts) do
    case DecisionQuery.get(decision_id, store: store(opts)) do
      {:ok, %{decision: decision}} -> authorize(decision, ticket_set)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  defp authorize(decision, ticket_set) do
    identifier = get_in(decision.ticket, [:identifier]) || get_in(decision.ticket, ["identifier"])

    if is_binary(identifier) and MapSet.member?(ticket_set, String.downcase(identifier)) do
      {:ok, decision}
    else
      # Same answer for a real but out-of-scope Command and for a missing one.
      {:error, :not_found}
    end
  end

  defp normalize_answer(payload) do
    payload =
      payload
      |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put(acc, to_string(key), value) end)
      |> Map.take([
        "idempotency_key",
        "expected_version",
        "option_id",
        "custom_response",
        "question_answers",
        "rationale"
      ])

    with {:ok, key} <- required_binary(payload, "idempotency_key", :idempotency_key),
         {:ok, version} <- expected_version(payload) do
      {:ok, payload |> Map.put("idempotency_key", key) |> Map.put("expected_version", version)}
    end
  end

  defp required_binary(payload, field, error_field) do
    case Map.get(payload, field) do
      value when is_binary(value) and value != "" ->
        if byte_size(value) > @maximum_answer_key_bytes,
          do: {:error, {:invalid_answer, {error_field, :too_long}}},
          else: {:ok, value}

      _missing ->
        {:error, {:invalid_answer, {error_field, :missing}}}
    end
  end

  defp expected_version(payload) do
    case Map.get(payload, "expected_version") do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_answer, {:expected_version, :invalid}}}
    end
  end

  defp operation(%{"replace" => true}), do: :override
  defp operation(_payload), do: :answer

  defp strip_control_keys(payload), do: Map.drop(payload, ["replace"])

  defp pagination(page) do
    %{
      "limit" => page.pagination.limit,
      "next_cursor" => page.pagination.next_cursor,
      "total" => page.pagination.total,
      "label" => page.pagination.label
    }
  end

  defp health(page) do
    %{
      "status" => Atom.to_string(page.health.status),
      "partial" => page.health.partial?,
      "reason" => page.health.reason
    }
  end

  defp restrict(params, key, maximum) do
    case Map.get(params, key, Map.get(params, String.to_atom(key))) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {limit, ""} when limit > maximum -> Map.put(params, key, maximum)
          _invalid -> params
        end

      value when is_integer(value) and value > maximum ->
        Map.put(params, key, maximum)

      _missing ->
        params
    end
  end

  defp store(opts), do: Keyword.get(opts, :store, DecisionQuery.default_store())

  @doc false
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit
end
