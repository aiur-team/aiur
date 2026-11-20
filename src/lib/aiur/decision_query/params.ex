defmodule Aiur.DecisionQuery.Params do
  @moduledoc false

  alias Aiur.Commands.Tags
  alias Aiur.Decision
  alias Aiur.DecisionQuery.Cursor

  @default_limit 25
  @maximum_limit 100
  @maximum_decision_id_bytes 256
  @maximum_search_bytes 200
  @query_fields ~w(authority blocking creator_inbox cursor kind labels lifecycle limit route search tag ticket tickets)
  @maximum_labels 50
  @label_pattern ~r/^[a-z0-9][a-z0-9_-]{0,63}:[a-z0-9][a-z0-9._-]{0,127}$/
  @lifecycle_by_name %{
    "open" => :open,
    # `awaiting` is the operator's own queue: open minus everything already
    # handed to the Executor. `history` is everything the operator has finished
    # with, which includes deferrals — the Executor owns those now.
    "awaiting" => :awaiting,
    "deferred" => :deferred,
    "historic" => :historic,
    "history" => :history,
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
          lifecycle:
            :open
            | :awaiting
            | :deferred
            | :historic
            | :history
            | :expired
            | :dismissed
            | :decided
            | :acknowledged
            | :resolved
            | nil,
          route: :needs_you | :with_executor | :from_executor | :resolved | nil,
          search: String.t() | nil,
          ticket: String.t() | nil,
          tickets: MapSet.t(String.t()) | nil,
          labels: [String.t()] | nil,
          tag: String.t() | nil,
          creator_inbox: boolean() | nil
        }

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_query, term()}}
  def parse(params) when is_map(params) do
    with {:ok, normalized} <- normalize_param_keys(params),
         {:ok, limit} <- bounded_integer(normalized["limit"], @default_limit, 1, @maximum_limit, :limit),
         {:ok, cursor} <- Cursor.parse(normalized["cursor"]),
         {:ok, authority} <- optional_authority(normalized["authority"]),
         {:ok, blocking} <- optional_boolean(normalized["blocking"]),
         {:ok, kind} <- optional_kind(normalized["kind"]),
         {:ok, route} <- optional_route(normalized["route"]),
         {:ok, lifecycle} <- optional_lifecycle(normalized["lifecycle"]),
         {:ok, ticket} <- optional_string(normalized["ticket"], @maximum_search_bytes, :ticket),
         {:ok, search} <- optional_string(normalized["search"], @maximum_search_bytes, :search),
         {:ok, tickets} <- optional_tickets(normalized["tickets"]),
         {:ok, labels} <- optional_labels(normalized["labels"]),
         {:ok, tag} <- optional_tag(normalized["tag"]),
         {:ok, creator_inbox} <- optional_creator_inbox(normalized["creator_inbox"]),
         :ok <- distinct_search_inputs(ticket, search) do
      {:ok,
       %{
         limit: limit,
         cursor: cursor,
         authority: authority,
         blocking: blocking,
         kind: kind,
         lifecycle: lifecycle,
         route: route,
         ticket: ticket,
         tickets: tickets,
         labels: labels,
         tag: tag,
         search: search,
         creator_inbox: creator_inbox
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

  defp optional_route(nil), do: {:ok, nil}

  defp optional_route(value) do
    case Enum.find([:needs_you, :with_executor, :from_executor, :resolved], &(value in [&1, Atom.to_string(&1)])) do
      nil -> {:error, {:route, :invalid}}
      route -> {:ok, route}
    end
  end

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

  # Narrow-only: `true` hides Executor-only Commands; it can never widen a read.
  defp optional_creator_inbox(value) when value in [nil, false, "false"], do: {:ok, nil}
  defp optional_creator_inbox(value) when value in [true, "true"], do: {:ok, true}
  defp optional_creator_inbox(_value), do: {:error, {:creator_inbox, :invalid}}

  defp optional_kind(nil), do: {:ok, nil}

  defp optional_kind(value) when is_binary(value) do
    with {:ok, kind} <- optional_string(value, @maximum_search_bytes, :kind) do
      {:ok, String.downcase(kind)}
    end
  end

  defp optional_kind(_value), do: {:error, {:kind, :invalid_type}}

  # A ticket set is an authorization input assembled by the caller, never a
  # user-facing query string: the ticket-scoped Commands API adds it after
  # parsing. It rides through the parsed query so the store can filter with it.
  defp optional_tickets(nil), do: {:ok, nil}
  defp optional_tickets(%MapSet{} = tickets), do: {:ok, tickets}

  defp optional_tickets(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, MapSet.new(list, fn ticket -> ticket |> String.trim() |> String.downcase() end)}
    else
      {:error, {:tickets, :invalid}}
    end
  end

  defp optional_tickets(_value), do: {:error, {:tickets, :invalid}}

  # A label scope (`game:chess`) filters Commands down to the tickets currently
  # carrying that label. It is accepted as a list or, on a query string, as one
  # comma-separated value.
  defp optional_labels(nil), do: {:ok, nil}

  defp optional_labels(value) when is_binary(value) do
    value |> String.split(",", trim: true) |> optional_labels()
  end

  defp optional_labels(%MapSet{} = labels), do: labels |> MapSet.to_list() |> optional_labels()

  defp optional_labels(list) when is_list(list) do
    normalized =
      list
      |> Enum.map(&normalize_label/1)
      |> Enum.uniq()

    cond do
      normalized == [] -> {:ok, nil}
      Enum.any?(normalized, &(&1 == :error)) -> {:error, {:labels, :invalid}}
      length(normalized) > @maximum_labels -> {:error, {:labels, :too_many}}
      true -> {:ok, normalized}
    end
  end

  defp optional_labels(_value), do: {:error, {:labels, :invalid}}

  defp normalize_label(label) when is_binary(label) do
    value = label |> String.trim() |> String.downcase()

    if String.valid?(value) and Regex.match?(@label_pattern, value), do: value, else: :error
  end

  defp normalize_label(_label), do: :error

  defp optional_tag(nil), do: {:ok, nil}

  defp optional_tag(tag) do
    case Tags.normalize([tag]) do
      {:ok, [tag]} -> {:ok, tag}
      _invalid -> {:error, {:tag, :invalid}}
    end
  end

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
