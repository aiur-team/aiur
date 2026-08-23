defmodule AiurWeb.StreamdeckCommands do
  @moduledoc false

  # Projects the decision store's Commands for one focused agent onto the
  # Stream Deck channel.
  #
  # The device's Commands page is history-first: opening it shows the agent's
  # past Commands (newest first) with active ones highlighted, and selecting an
  # open one enters the answer flow. This module is a strict DTO allowlist over
  # `Aiur.DecisionQuery`/`Aiur.DecisionStore` — it never passes an internal
  # struct field to the device that the client did not ask to render.

  alias Aiur.{Decision, DecisionAnswer, DecisionQuery}

  # The operator identity recorded on a Command answered from the device. The
  # operator physically pressing their own deck is the operator answering, so
  # every device answer is attributed here — never as an Executor answer with an
  # operator flavour in free text.
  @actor_id "streamdeck"
  @history_limit 8
  @option_fields ~w(id label description benefits drawbacks risk)a

  @doc """
  One page of the focused agent's Command history, newest first.

  `cursor` is an opaque base64 cursor from the previous page (or nil for the
  first). The page is bounded at `@history_limit` so an agent with many past
  Commands pages instead of overflowing the key grid. An unreadable store is
  projected as a page flagged `"unavailable"` rather than as an empty history,
  so the device says "Commands unavailable" instead of silently showing no
  Commands for an agent that has them.
  """
  @spec history(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def history(identifier, cursor, opts \\ []) when is_binary(identifier) do
    limit = Keyword.get(opts, :limit, @history_limit)

    case DecisionQuery.list(%{ticket: identifier, limit: limit, cursor: cursor}, store: store(opts)) do
      {:ok, result} ->
        {:ok, page(result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "One exact Command, allowlisted — used to project an answer's recorded result back to the device."
  @spec detail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def detail(decision_id, opts \\ []) when is_binary(decision_id) do
    case DecisionQuery.get(decision_id, store: store(opts)) do
      {:ok, %{decision: decision}} -> {:ok, item(decision)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Allowlisted JSON-safe projection of one Decision for the device."
  @spec item(Decision.t()) :: map()
  def item(%Decision{} = decision) do
    %{
      "decision_id" => decision.decision_id,
      "version" => decision.version,
      "ticket" => %{"identifier" => get_in(decision.ticket, [:identifier])},
      "question" => decision.question,
      "context" => context(decision.context),
      "options" => Enum.map(decision.options, &option/1),
      "status" => Atom.to_string(decision.decision_status),
      "blocking" => decision.blocking,
      "answer" => answer(Decision.active_answer(decision)),
      "created_at" => DateTime.to_iso8601(decision.created_at)
    }
  end

  @doc "The device-side operator identity for a Command answer recorded on the deck."
  @spec actor() :: %{kind: :operator, id: String.t()}
  def actor, do: %{kind: :operator, id: @actor_id}

  defp page(result) do
    %{
      "items" => Enum.map(result.decisions, &item/1),
      "next_cursor" => get_in(result, [:pagination, :next_cursor]),
      "has_next" => get_in(result, [:pagination, :next_cursor]) != nil,
      "total" => get_in(result, [:pagination, :total]),
      "partial" => Map.get(result, :partial_results?, false) == true,
      # A store that could not be read surfaces an unavailable page rather than
      # an empty history, so the device says so instead of showing no Commands.
      "unavailable" => Map.get(result, :partial_reason) == :retained_store_unavailable
    }
  end

  defp context(context) when is_map(context) do
    %{
      "short" => Map.get(context, :short_summary),
      "long" => Map.get(context, :long_context_markdown)
    }
    |> reject_nils()
  end

  defp context(_context), do: %{}

  defp option(option) when is_map(option) do
    Map.new(@option_fields, fn field -> {Atom.to_string(field), Map.get(option, field)} end)
    |> reject_nils()
  end

  defp option(_option), do: %{}

  defp answer(nil), do: nil

  defp answer(%DecisionAnswer{selected_option_id: option_id, custom_response: response, actor: actor}) do
    %{"selected_option_id" => option_id, "custom_response" => response, "actor" => actor(actor)}
    |> reject_nils()
  end

  defp actor(actor) when is_map(actor) do
    %{"kind" => kind_string(Map.get(actor, :kind))}
    |> then(fn projected ->
      case Map.get(actor, :id) do
        id when is_binary(id) and id != "" -> Map.put(projected, "id", id)
        _ -> projected
      end
    end)
  end

  defp kind_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_string(kind) when is_binary(kind), do: kind

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp store(opts), do: Keyword.get(opts, :store, DecisionQuery.default_store())
end
