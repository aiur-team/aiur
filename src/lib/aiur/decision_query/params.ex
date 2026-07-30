defmodule Aiur.DecisionQuery.Params do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionQuery.Cursor

  @default_limit 25
  @maximum_limit 100
  @maximum_decision_id_bytes 256
  @maximum_search_bytes 200
  @query_fields ~w(authority blocking cursor kind lifecycle limit search ticket)
  @lifecycle_by_name %{
    "open" => :open,
    "deferred" => :deferred,
    "historic" => :historic,
    "expired" => :expired,
    "dismissed" => :dismissed,
    "decided" => :decided,
    "acknowledged" => :acknowledged,
    "resolved" => :resolved
  }

  @type t :: %{
          limit: pos_integer(),
          cursor: Cursor.t() | nil,
          authority: Decision.authority() | nil,
          blocking: boolean() | nil,
          kind: String.t() | nil,
          lifecycle: :open | :deferred | :historic | :expired | :dismissed | :decided | :acknowledged | :resolved | nil,
          search: String.t() | nil,
          ticket: String.t() | nil
        }

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_query, term()}}
  def parse(params) when is_map(params) do
    with {:ok, normalized} <- normalize_param_keys(params),
         {:ok, limit} <- bounded_integer(normalized["limit"], @default_limit, 1, @maximum_limit, :limit),
         {:ok, cursor} <- Cursor.parse(normalized["cursor"]),
         {:ok, authority} <- optional_authority(normalized["authority"]),
         {:ok, blocking} <- optional_boolean(normalized["blocking"]),
         {:ok, kind} <- optional_kind(normalized["kind"]),
         {:ok, lifecycle} <- optional_lifecycle(normalized["lifecycle"]),
         {:ok, ticket} <- optional_string(normalized["ticket"], @maximum_search_bytes, :ticket),
         {:ok, search} <- optional_string(normalized["search"], @maximum_search_bytes, :search),
         :ok <- distinct_search_inputs(ticket, search) do
      {:ok,
       %{
         limit: limit,
         cursor: cursor,
         authority: authority,
         blocking: blocking,
         kind: kind,
         lifecycle: lifecycle,
         ticket: ticket,
         search: search
       }}
    else
      {:error, reason} -> {:error, {:invalid_query, reason}}
    end
  end

  def parse(_params), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  @spec normalize_decision_id(term()) :: {:ok, String.t()} | {:error, {:invalid_decision_id, atom()}}
  def normalize_decision_id(decision_id) when is_binary(decision_id) do
    if String.valid?(decision_id),
      do: validate_decision_id(decision_id, String.trim(decision_id)),
      else: {:error, {:invalid_decision_id, :malformed}}
  end

  def normalize_decision_id(_decision_id), do: {:error, {:invalid_decision_id, :invalid_type}}

  defp normalize_param_keys(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(raw_key),
           :ok <- validate_query_field(key),
           :ok <- reject_duplicate(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, {:field, :invalid}}

  defp validate_query_field(key) when key in @query_fields, do: :ok
  defp validate_query_field(key), do: {:error, {:field, key, :unknown}}

  defp reject_duplicate(params, key) do
    if Map.has_key?(params, key), do: {:error, {:field, key, :duplicate}}, else: :ok
  end

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

  defp optional_lifecycle(nil), do: {:ok, nil}
  defp optional_lifecycle(value) when is_atom(value), do: optional_lifecycle(Atom.to_string(value))

  defp optional_lifecycle(value) when is_binary(value) do
    if String.valid?(value) do
      case Map.fetch(@lifecycle_by_name, String.downcase(String.trim(value))) do
        {:ok, lifecycle} -> {:ok, lifecycle}
        :error -> {:error, {:lifecycle, :invalid}}
      end
    else
      {:error, {:lifecycle, :invalid}}
    end
  end

  defp optional_lifecycle(_value), do: {:error, {:lifecycle, :invalid}}

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

  defp optional_kind(nil), do: {:ok, nil}

  defp optional_kind(value) when is_binary(value) do
    with {:ok, kind} <- optional_string(value, @maximum_search_bytes, :kind) do
      {:ok, String.downcase(kind)}
    end
  end

  defp optional_kind(_value), do: {:error, {:kind, :invalid_type}}

  defp optional_string(nil, _maximum, _field), do: {:ok, nil}

  defp optional_string(value, maximum, field) when is_binary(value) do
    if String.valid?(value) do
      trimmed = String.trim(value)

      cond do
        trimmed == "" -> {:error, {field, :missing}}
        byte_size(trimmed) > maximum -> {:error, {field, :too_long}}
        unsafe_control_chars?(value) -> {:error, {field, :unsafe_characters}}
        true -> {:ok, trimmed}
      end
    else
      {:error, {field, :invalid_encoding}}
    end
  end

  defp optional_string(_value, _maximum, field), do: {:error, {field, :invalid_type}}

  defp distinct_search_inputs(nil, _search), do: :ok
  defp distinct_search_inputs(_ticket, nil), do: :ok
  defp distinct_search_inputs(_ticket, _search), do: {:error, {:search, :conflicts_with_ticket}}

  defp validate_decision_id(decision_id, trimmed) do
    cond do
      trimmed == "" -> {:error, {:invalid_decision_id, :missing}}
      byte_size(trimmed) > @maximum_decision_id_bytes -> {:error, {:invalid_decision_id, :too_long}}
      trimmed != decision_id or unsafe_control_chars?(decision_id) -> {:error, {:invalid_decision_id, :malformed}}
      true -> {:ok, decision_id}
    end
  end

  defp unsafe_control_chars?(value), do: String.match?(value, ~r/[\x00-\x1F\x7F]/)
end
