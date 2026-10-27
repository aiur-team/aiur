defmodule Aiur.Orchestrator.SpendCap.Record do
  @moduledoc false

  alias Aiur.{JSONSafe, TrackerIdentity}

  @contract "aiur.ticket_spend_cap"
  @contract_version 1
  @schema_version 1
  @currency "USD"
  @effect_names [:stop, :event, :tracker_transition]
  @amount_pattern ~r/\A(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?\z/

  @enforce_keys [:identity, :cap, :configured_at]
  defstruct identity: nil,
            cap: nil,
            configured_at: nil,
            state: :active,
            end_state: nil,
            spent: Decimal.new(0),
            coverage: %{status: :complete, known: 0, unknown: 0, reasons: []},
            authority: %{},
            reached_at: nil,
            event_id: nil,
            effects: %{stop: :not_applicable, event: :not_applicable, tracker_transition: :not_applicable}

  @type state :: :active | :unavailable | :budget_exhausted
  @type effect_state :: :not_applicable | :pending | :completed
  @type t :: %__MODULE__{
          identity: TrackerIdentity.t(),
          cap: Decimal.t(),
          configured_at: DateTime.t(),
          state: state(),
          end_state: :budget_exhausted | nil,
          spent: Decimal.t() | nil,
          coverage: map(),
          authority: map(),
          reached_at: DateTime.t() | nil,
          event_id: pos_integer() | nil,
          effects: %{required(atom()) => effect_state()}
        }

  @spec new(TrackerIdentity.t(), term(), DateTime.t()) :: {:ok, t()} | {:error, :invalid_identity | :invalid_amount}
  def new(%TrackerIdentity{} = identity, amount, %DateTime{} = configured_at) do
    with true <- TrackerIdentity.joinable?(identity),
         {:ok, cap} <- amount(amount),
         true <- Decimal.compare(cap, Decimal.new(0)) == :gt do
      {:ok, %__MODULE__{identity: identity, cap: cap, configured_at: configured_at}}
    else
      false -> {:error, if(TrackerIdentity.joinable?(identity), do: :invalid_amount, else: :invalid_identity)}
      {:error, _reason} = error -> error
    end
  end

  def new(_identity, _amount, _configured_at), do: {:error, :invalid_identity}

  @spec new!(TrackerIdentity.t(), term(), DateTime.t()) :: t()
  def new!(identity, amount, configured_at) do
    {:ok, record} = new(identity, amount, configured_at)
    record
  end

  @spec amount(term()) :: {:ok, Decimal.t()} | {:error, :invalid_amount}
  def amount(value) when is_binary(value) do
    if Regex.match?(@amount_pattern, value) do
      case Decimal.parse(value) do
        {amount, ""} -> {:ok, amount}
        _other -> {:error, :invalid_amount}
      end
    else
      {:error, :invalid_amount}
    end
  end

  def amount(_value), do: {:error, :invalid_amount}

  @spec key(t() | TrackerIdentity.t()) :: tuple() | nil
  def key(%__MODULE__{identity: identity}), do: TrackerIdentity.github_key(identity)
  def key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)

  @spec effect(t(), atom(), effect_state()) :: t()
  def effect(%__MODULE__{} = record, name, value) when name in @effect_names and value in [:not_applicable, :pending, :completed] do
    %{record | effects: Map.put(record.effects, name, value)}
  end

  @spec next_effect(t()) :: atom() | nil
  def next_effect(%__MODULE__{state: :budget_exhausted, effects: effects}) do
    Enum.find(@effect_names, &(Map.get(effects, &1) != :completed))
  end

  def next_effect(_record), do: nil

  @spec public(t()) :: map()
  def public(%__MODULE__{} = record) do
    remaining = if record.spent, do: Decimal.max(Decimal.sub(record.cap, record.spent), Decimal.new(0)), else: nil

    JSONSafe.normalize(%{
      contract: @contract,
      contract_version: @contract_version,
      schema_version: @schema_version,
      job_id: record.identity.identifier,
      ticket: %{owner: record.identity.owner, repository: record.identity.repository, identifier: record.identity.identifier},
      currency: @currency,
      cap_amount: decimal(record.cap),
      spent_amount: decimal(record.spent),
      remaining_amount: decimal(remaining),
      state: record.state,
      end_state: record.end_state,
      coverage: record.coverage,
      authority: record.authority,
      configured_at: DateTime.to_iso8601(record.configured_at),
      reached_at: iso8601(record.reached_at),
      effects: record.effects
    })
  end

  @spec event_payload(t()) :: map()
  def event_payload(%__MODULE__{} = record) do
    record
    |> public()
    |> Map.drop(["effects"])
    |> Map.put("contract", "aiur.ticket_spend_cap_reached")
  end

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = record) do
    %{
      "identity" => Map.from_struct(record.identity) |> JSONSafe.normalize(),
      "cap_amount" => decimal(record.cap),
      "configured_at" => DateTime.to_iso8601(record.configured_at),
      "state" => Atom.to_string(record.state),
      "end_state" => if(record.end_state, do: Atom.to_string(record.end_state), else: nil),
      "spent_amount" => decimal(record.spent),
      "coverage" => JSONSafe.normalize(record.coverage),
      "authority" => JSONSafe.normalize(record.authority),
      "reached_at" => iso8601(record.reached_at),
      "event_id" => record.event_id,
      "effects" => Map.new(record.effects, fn {name, value} -> {Atom.to_string(name), Atom.to_string(value)} end)
    }
  end

  @spec decode(map()) :: {:ok, t()} | :error
  def decode(%{"identity" => identity, "cap_amount" => cap, "configured_at" => configured_at, "state" => state, "effects" => effects} = data) do
    with {:ok, identity} <- decode_identity(identity),
         {:ok, cap} <- amount(cap),
         {:ok, configured_at, 0} <- DateTime.from_iso8601(configured_at),
         {:ok, state} <- decode_state(state),
         {:ok, end_state} <- decode_end_state(Map.get(data, "end_state")),
         {:ok, spent} <- decode_optional_amount(Map.get(data, "spent_amount")),
         {:ok, reached_at} <- decode_datetime(Map.get(data, "reached_at")),
         {:ok, effects} <- decode_effects(effects),
         event_id when is_nil(event_id) or (is_integer(event_id) and event_id > 0) <- Map.get(data, "event_id"),
         record = %__MODULE__{
           identity: identity,
           cap: cap,
           configured_at: configured_at,
           state: state,
           end_state: end_state,
           spent: spent,
           coverage: Map.get(data, "coverage", %{}),
           authority: Map.get(data, "authority", %{}),
           reached_at: reached_at,
           event_id: event_id,
           effects: effects
         },
         true <- valid?(record) do
      {:ok, record}
    else
      _other -> :error
    end
  end

  def decode(_data), do: :error

  defp decode_identity(%{"version" => 1, "status" => "joinable", "kind" => "github"} = identity) do
    decoded = %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: identity["owner"],
      repository: identity["repository"],
      provider_id: identity["provider_id"],
      database_id: identity["database_id"],
      identifier: identity["identifier"],
      reason: nil
    }

    if TrackerIdentity.joinable?(decoded), do: {:ok, decoded}, else: :error
  end

  defp decode_identity(_identity), do: :error
  defp decode_state(state) when state in ["active", "unavailable", "budget_exhausted"], do: {:ok, String.to_existing_atom(state)}
  defp decode_state(_state), do: :error
  defp decode_end_state(nil), do: {:ok, nil}
  defp decode_end_state("budget_exhausted"), do: {:ok, :budget_exhausted}
  defp decode_end_state(_state), do: :error
  defp decode_optional_amount(nil), do: {:ok, nil}
  defp decode_optional_amount(value), do: amount(value)
  defp decode_datetime(nil), do: {:ok, nil}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> :error
    end
  end

  defp decode_datetime(_value), do: :error

  defp decode_effects(effects) when is_map(effects) do
    Enum.reduce_while(@effect_names, {:ok, %{}}, fn name, {:ok, decoded} ->
      case Map.get(effects, Atom.to_string(name)) do
        "pending" -> {:cont, {:ok, Map.put(decoded, name, :pending)}}
        "completed" -> {:cont, {:ok, Map.put(decoded, name, :completed)}}
        "not_applicable" -> {:cont, {:ok, Map.put(decoded, name, :not_applicable)}}
        _other -> {:halt, :error}
      end
    end)
  end

  defp decode_effects(_effects), do: :error

  defp valid?(%__MODULE__{} = record) do
    Decimal.compare(record.cap, Decimal.new(0)) == :gt and is_map(record.coverage) and is_map(record.authority) and
      valid_state?(record)
  end

  defp valid_state?(%__MODULE__{state: :active, end_state: nil, spent: %Decimal{}, reached_at: nil, event_id: nil} = record),
    do: effects?(record.effects, [:not_applicable])

  defp valid_state?(%__MODULE__{state: :unavailable, end_state: nil, spent: nil, reached_at: nil, event_id: nil} = record),
    do: effects?(record.effects, [:not_applicable])

  defp valid_state?(%__MODULE__{state: :budget_exhausted, end_state: :budget_exhausted, spent: %Decimal{}, reached_at: %DateTime{}} = record) do
    Decimal.compare(record.spent, record.cap) in [:eq, :gt] and
      DateTime.compare(record.reached_at, record.configured_at) in [:eq, :gt] and valid_exhausted_effects?(record)
  end

  defp valid_state?(_record), do: false
  defp effects?(effects, allowed), do: Enum.all?(@effect_names, &(Map.get(effects, &1) in allowed))

  defp valid_exhausted_effects?(%__MODULE__{effects: effects, event_id: event_id}) do
    case effects do
      %{stop: :pending, event: :pending, tracker_transition: :pending} -> is_nil(event_id)
      %{stop: :completed, event: :pending, tracker_transition: :pending} -> is_nil(event_id) or is_integer(event_id)
      %{stop: :completed, event: :completed, tracker_transition: :pending} -> is_integer(event_id)
      %{stop: :completed, event: :completed, tracker_transition: :completed} -> is_integer(event_id)
      _other -> false
    end
  end

  defp decimal(nil), do: nil
  defp decimal(amount), do: Decimal.to_string(amount, :normal)
  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
