defmodule Aiur.Commands.ComponentState do
  @moduledoc """
  The presentation contract shared by Aiur's dashboard Command cards and an
  embedding host application.

  One Command projection becomes one component map. The map carries the stable
  lifecycle state, the options, the recommendation signal, whether a free
  response is accepted, the accepted answer and any typed media. Dashboard
  cards and host renderers read the same map so the two surfaces cannot drift.

  `from_projection/2` accepts the canonical v2 Command projection produced by
  `Aiur.DecisionApi` as well as the dashboard row from
  `AiurWeb.OperatorControlCenter.DecisionPresenter`; atom- and string-keyed
  maps are both understood. The contract itself always uses string keys so it
  can cross an HTTP or JSON boundary unchanged. The `"media"` list it carries
  is built by `Aiur.Commands.ComponentState.Media`.
  """

  alias Aiur.Commands.Answering.Outcome
  alias Aiur.Commands.ComponentState.Media, as: ComponentMedia

  @states ~w(pending answered revised expired unavailable conflict error)
  @list_states ~w(loading empty ready unavailable error)

  @type state ::
          :pending
          | :answered
          | :revised
          | :expired
          | :unavailable
          | :conflict
          | :error

  @type t :: %{String.t() => term()}

  @doc "Every Command-level component state."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Every list-level component state."
  @spec list_states() :: [String.t()]
  def list_states, do: @list_states

  @doc """
  Builds the documented component map from one Command projection.

  Options:

    * `:writable` - whether the caller may answer or revise (default `true`)
    * `:error` - a component error reason when the read itself failed
  """
  @spec from_projection(map(), keyword()) :: t()
  def from_projection(projection, opts \\ [])

  def from_projection(projection, opts) when is_map(projection) do
    projection = normalize(projection)
    {state, reason} = derive(projection, opts)
    writable? = Keyword.get(opts, :writable, true)
    options = options(projection)

    %{
      "state" => Atom.to_string(state),
      "reason" => reason,
      "decision_id" => text(projection, "decision_id"),
      "version" => Map.get(projection, "version"),
      "question" => text(projection, "question"),
      "ticket" => ticket(projection),
      "blocking" => Map.get(projection, "blocking") == true,
      "options" => options,
      "recommendation" => recommendation(projection, options),
      "free_response" => free_response(options),
      "answer" => answer(projection),
      "conflict" => conflict(projection),
      "media" => media(projection),
      "actions" => actions(state, writable?),
      "source" => text(projection, "source")
    }
  end

  def from_projection(_projection, opts) do
    error(:invalid_projection, "Command projection is unavailable", opts)
  end

  @doc "The documented component map for a failed read or write."
  @spec error(term(), String.t(), keyword()) :: t()
  def error(reason, message, opts \\ []) when is_atom(reason) do
    %{
      "state" => state_for_reason(reason),
      "reason" => Atom.to_string(reason),
      "decision_id" => Keyword.get(opts, :decision_id),
      "version" => Keyword.get(opts, :version),
      "question" => nil,
      "ticket" => nil,
      "blocking" => false,
      "options" => [],
      "recommendation" => nil,
      "free_response" => %{"allowed" => false, "required" => false},
      "answer" => nil,
      "conflict" => nil,
      "media" => [],
      "actions" => actions(:error, false),
      "source" => nil,
      "message" => message
    }
  end

  @doc """
  Builds the list-level component map from already-built Command components.

  `:error` short-circuits to the error list state; an empty page is `empty`
  rather than a silent `ready` so hosts do not render a blank surface.
  """
  @spec list([t()], keyword()) :: map()
  def list(commands, opts \\ [])

  def list(commands, opts) when is_list(commands) do
    case Keyword.get(opts, :error) do
      nil ->
        %{
          "status" => if(commands == [], do: "empty", else: "ready"),
          "commands" => commands,
          "count" => length(commands),
          "error" => nil
        }

      reason ->
        %{"status" => "error", "commands" => [], "count" => 0, "error" => error_payload(reason)}
    end
  end

  def list(_commands, opts) do
    %{
      "status" => "error",
      "commands" => [],
      "count" => 0,
      "error" => error_payload(Keyword.get(opts, :error, :invalid_commands))
    }
  end

  @doc "The loading list state, for a host whose request is still in flight."
  @spec loading() :: map()
  def loading do
    %{"status" => "loading", "commands" => [], "count" => 0, "error" => nil}
  end

  @doc """
  Maps a canonical `Aiur.Commands.Answering` outcome onto the component state.

  This is the one place stale versions, duplicate submits, already-answered
  Commands, withdrawn Commands, permission refusals and validation failures
  become stable component states. Hosts never translate store errors
  themselves.
  """
  @spec from_outcome(Outcome.t() | term(), keyword()) :: t()
  def from_outcome(outcome, opts \\ [])

  def from_outcome(%{status: status} = outcome, opts) when is_map(outcome) do
    decision = Map.get(outcome, :decision)
    base = projection_for_decision(decision, opts)
    merge_outcome(base, status, outcome)
  end

  def from_outcome({:error, reason}, opts), do: validation_state(reason, opts)
  def from_outcome(_outcome, opts), do: error(:store_unavailable, "Command state could not be read", opts)

  defp merge_outcome(base, status, _outcome) when status in [:accepted, :duplicate] do
    reason = if status == :duplicate, do: "duplicate_submit", else: nil
    base |> Map.merge(%{"state" => answer_state(base), "reason" => reason}) |> Map.put("conflict", nil)
  end

  defp merge_outcome(base, :already_answered, outcome) do
    conflict = %{"kind" => "already_answered", "winner" => winner(outcome)}

    base
    |> Map.merge(%{"state" => "conflict", "reason" => "already_answered", "conflict" => conflict})
  end

  defp merge_outcome(base, :too_late, outcome) do
    conflict = %{"kind" => "too_late", "reason" => to_string(outcome.reason), "winner" => winner(outcome)}

    base
    |> Map.merge(%{"state" => "conflict", "reason" => "answer_in_flight", "conflict" => conflict})
  end

  defp merge_outcome(base, :stale, outcome) do
    base
    |> Map.merge(%{
      "state" => "conflict",
      "reason" => "stale_version",
      "version" => Map.get(outcome, :current_version, base["version"])
    })
  end

  defp merge_outcome(base, :withdrawn, outcome) do
    base |> Map.merge(%{"state" => "expired", "reason" => to_string(outcome.reason)})
  end

  defp merge_outcome(base, :not_allowed, outcome) do
    base
    |> Map.merge(%{
      "state" => "error",
      "reason" => "not_allowed",
      "message" => "This Command cannot be answered by this caller (#{outcome.reason})"
    })
  end

  defp merge_outcome(base, :error, outcome) do
    merge_error_outcome(base, outcome.reason)
  end

  defp merge_outcome(base, _status, _outcome), do: base

  # A rejected write is not a read failure: keep the store's reason vocabulary
  # so hosts can distinguish "your answer was wrong" from "the store is down".
  defp merge_error_outcome(base, {:answer_invalid, _detail}),
    do: Map.merge(base, %{"state" => "error", "reason" => "validation_failed", "message" => "Answer failed validation"})

  defp merge_error_outcome(base, {:response, _detail}),
    do: Map.merge(base, %{"state" => "error", "reason" => "validation_failed", "message" => "Answer failed validation"})

  defp merge_error_outcome(base, {:question_answers, _detail}),
    do: Map.merge(base, %{"state" => "error", "reason" => "validation_failed", "message" => "Answer failed validation"})

  defp merge_error_outcome(base, {:conflict, {:stale_version, _expected, current}}),
    do: Map.merge(base, %{"state" => "conflict", "reason" => "stale_version", "version" => current})

  defp merge_error_outcome(base, {:conflict, _detail}),
    do: Map.merge(base, %{"state" => "conflict", "reason" => "already_answered"})

  defp merge_error_outcome(base, :store_unavailable),
    do: Map.merge(base, %{"state" => "unavailable", "reason" => "store_unavailable"})

  defp merge_error_outcome(base, reason) do
    base
    |> Map.merge(%{"state" => "error", "reason" => "store_error"})
    |> Map.put("message", "Command state could not be read (#{inspect(reason)})")
  end

  defp validation_state({:answer_invalid, _detail} = reason, opts),
    do: error(:validation_failed, "Answer failed validation", Keyword.put(opts, :reason, reason))

  defp validation_state({:conflict, {:stale_version, _expected, _current}} = reason, opts),
    do: error(:stale_version, "Command changed; refresh and retry", Keyword.put(opts, :reason, reason))

  defp validation_state({:conflict, _detail} = reason, opts),
    do: error(:conflict, "Command changed; refresh and retry", Keyword.put(opts, :reason, reason))

  defp validation_state({:response, _detail} = reason, opts),
    do: error(:validation_failed, "Answer failed validation", Keyword.put(opts, :reason, reason))

  defp validation_state(:store_unavailable, opts),
    do: error(:store_unavailable, "Command store is unavailable", opts)

  defp validation_state(reason, opts),
    do: error(:invalid_answer, "Answer could not be recorded", Keyword.put(opts, :reason, reason))

  defp answer_state(%{"state" => "revised"}), do: "revised"
  defp answer_state(_base), do: "answered"

  defp projection_for_decision(nil, opts) do
    Map.put(from_projection(%{}, Keyword.put(opts, :writable, false)), "state", "pending")
  end

  defp projection_for_decision(decision, opts) when is_map(decision) do
    decision
    |> decision_projection()
    |> from_projection(Keyword.put(opts, :writable, false))
  end

  defp projection_for_decision(_decision, opts) do
    Map.put(from_projection(%{}, Keyword.put(opts, :writable, false)), "state", "pending")
  end

  defp decision_projection(decision) do
    %{
      "decision_id" => Map.get(decision, :decision_id),
      "version" => Map.get(decision, :version),
      "question" => Map.get(decision, :question),
      "ticket" => Map.get(decision, :ticket),
      "blocking" => Map.get(decision, :blocking),
      "options" => Map.get(decision, :options, []),
      "recommendation" => Map.get(decision, :recommendation),
      "artifacts" => Map.get(decision, :artifacts, []),
      "decision_status" => Map.get(decision, :decision_status),
      "delivery_status" => Map.get(decision, :delivery_status),
      "revision_sequence" => Map.get(decision, :revision_sequence, 0),
      "answer" => Map.get(decision, :answer),
      "active_answer" => Map.get(decision, :active_answer)
    }
  end

  defp derive(projection, opts) do
    case Keyword.get(opts, :error) do
      nil -> derive_state(projection)
      reason -> {:error, to_string(reason)}
    end
  end

  defp derive_state(projection) do
    cond do
      terminal = terminal_state(projection) -> terminal
      unavailable?(projection) -> {:unavailable, "store_unavailable"}
      conflict?(projection) -> {:conflict, "stale_version"}
      answered?(projection) and revised?(projection) -> {:revised, "superseded_answer"}
      answered?(projection) -> {:answered, nil}
      true -> {:pending, nil}
    end
  end

  defp terminal_state(projection) do
    case projection["decision_status"] do
      status when status in [:expired, "expired"] -> {:expired, "expired"}
      status when status in [:moot, "moot"] -> {:expired, "moot"}
      status when status in [:dismissed, "dismissed"] -> {:expired, "dismissed"}
      _open -> nil
    end
  end

  defp conflict?(projection) do
    projection["conflict_summary"] not in [nil, %{}] and answered?(projection) and stale?(projection)
  end

  defp unavailable?(projection) do
    get_in(projection, ["health", "status"]) in [:partial, "partial", :unavailable, "unavailable"] or
      Map.get(projection, "store_available") == false
  end

  defp answered?(projection) do
    projection["active_answer"] not in [nil, %{}] or projection["answer"] not in [nil, %{}] or
      projection["decision_status"] in [:decided, "decided", :acknowledged, "acknowledged", :resolved, "resolved"]
  end

  defp revised?(projection) do
    sequence = Map.get(projection, "revision_sequence", 0)
    is_integer(sequence) and sequence > 0
  end

  defp stale?(projection) do
    case projection["conflict_summary"] do
      %{"stale" => true} -> true
      %{stale: true} -> true
      _summary -> false
    end
  end

  defp actions(state, writable?) do
    %{
      "answer" => writable? and state == :pending,
      "revise" => writable? and state in [:answered, :revised],
      "enrich" => false
    }
  end

  defp options(projection) do
    projection
    |> Map.get("options", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn option ->
      %{
        "id" => text(option, "id"),
        "label" => text(option, "label"),
        "description" => text(option, "description"),
        "benefits" => text(option, "benefits"),
        "drawbacks" => text(option, "drawbacks"),
        "risk" => text(option, "risk")
      }
      |> Map.merge(ComponentMedia.option_media(option))
    end)
  end

  defp recommendation(projection, options) do
    recommended_id =
      projection
      |> Map.get("recommendation")
      |> case do
        %{} = recommendation when map_size(recommendation) > 0 -> text(recommendation, "option_id")
        _missing -> nil
      end

    case Enum.find(options, &(&1["id"] == recommended_id)) do
      nil -> nil
      option -> %{"option_id" => option["id"], "label" => option["label"]}
    end
  end

  defp free_response(options) do
    %{"allowed" => true, "required" => options == []}
  end

  defp answer(projection) do
    projection
    |> active_answer()
    |> case do
      answer when is_map(answer) -> answer_map(answer)
      _missing -> nil
    end
  end

  defp active_answer(projection) do
    case Map.get(projection, "active_answer") do
      %{} = answer when map_size(answer) > 0 -> answer
      _missing -> Map.get(projection, "answer")
    end
  end

  defp answer_map(answer) do
    %{
      "action_id" => text(answer, "action_id"),
      "decision_version" => get_key(answer, "decision_version"),
      "selected_option_id" => text(answer, "selected_option_id"),
      "custom_response" => text(answer, "custom_response"),
      "rationale" => text(answer, "rationale"),
      "accepted_at" => get_key(answer, "accepted_at")
    }
    |> put_feedback(get_key(answer, "feedback"))
  end

  # Text-only answers keep the old shape.
  defp put_feedback(map, [_ | _] = feedback), do: Map.put(map, "feedback", feedback)
  defp put_feedback(map, _none), do: map

  defp conflict(%{"state" => "conflict"} = projection), do: Map.get(projection, "conflict")
  defp conflict(_projection), do: nil

  defp media(projection), do: ComponentMedia.list(projection)

  defp ticket(%{"ticket" => %{} = ticket}) do
    %{
      "identifier" => text(ticket, "identifier"),
      "title" => text(ticket, "title"),
      "url" => text(ticket, "url")
    }
  end

  defp ticket(_projection), do: nil

  defp winner(%{winner: %{} = winner}) do
    %{"actor" => text(winner, "actor"), "answered_at" => get_key(winner, "answered_at")}
  end

  defp winner(_outcome), do: nil

  defp state_for_reason(reason) when reason in [:conflict, :stale_version, :already_answered], do: "conflict"
  defp state_for_reason(_reason), do: "error"

  defp error_payload(reason) when is_atom(reason), do: %{"reason" => Atom.to_string(reason)}
  defp error_payload(%{} = reason), do: stringify(reason)
  defp error_payload(reason), do: %{"reason" => "invalid_request", "detail" => inspect(reason)}

  # Normalizes atom/string keys recursively so the contract reads one shape
  # from both the canonical JSON projection and the dashboard row.
  defp normalize(%{__struct__: _module} = value), do: value
  defp normalize(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value

  defp stringify(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc -> Map.put(acc, to_string(key), value) end)
  end

  defp text(map, key) when is_map(map) do
    case get_key(map, key) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp text(_map, _key), do: nil

  # API projections carry string keys; persisted structs (answers, tickets,
  # artifacts) keep atom fields. Reading both keeps one contract for both.
  defp get_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom(key) do
          nil -> nil
          atom -> Map.get(map, atom)
        end
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
