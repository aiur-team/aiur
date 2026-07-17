defmodule AiurWeb.BuildOrder.TicketContextSelection do
  @moduledoc """
  Pure root/generation-scoped selection policy for Build Order ticket context.

  Navigation values, request tokens, and origin identifiers are deterministic,
  bounded, and derived from exact repository-qualified identities. The reducer
  performs no I/O and retains no client-only selection cache.
  """

  alias Aiur.BuildOrder.Bounded
  alias Aiur.OpaqueIdentifier
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.Node

  @max_history 100
  @events %{
    replace: "build-order-context-replace",
    back: "build-order-context-back",
    close: "build-order-context-close"
  }

  @type status :: :closed | :open
  @type t :: %__MODULE__{
          status: status(),
          root_key: term() | nil,
          generation: pos_integer() | nil,
          selected: TrackerIdentity.t() | nil,
          history: [TrackerIdentity.t()],
          origin_id: String.t() | nil,
          request_sequence: non_neg_integer(),
          request_token: String.t() | nil,
          focus_revision: non_neg_integer()
        }

  defstruct status: :closed,
            root_key: nil,
            generation: nil,
            selected: nil,
            history: [],
            origin_id: nil,
            request_sequence: 0,
            request_token: nil,
            focus_revision: 0

  @doc "Returns an empty disposable selection state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the fixed navigation-only event names owned by BO-011."
  @spec event_names() :: %{replace: String.t(), back: String.t(), close: String.t()}
  def event_names, do: @events

  @doc "Returns the maximum number of prior exact selections retained for back navigation."
  @spec max_history() :: pos_integer()
  def max_history, do: @max_history

  @doc "Returns a deterministic opaque navigation value for one unique current member."
  @spec navigation_value(BuildOrderViewModel.t(), term()) :: String.t() | nil
  def navigation_value(%BuildOrderViewModel{} = model, identity) do
    with {:ok, {root_key, generation}} <- scope(model),
         %Node{key: key, identity: member_identity} <- exact_member(model, identity),
         true <- same_repository?(model.root, member_identity) do
      navigation_value_for_scope(root_key, generation, key)
    else
      _ -> nil
    end
  end

  def navigation_value(_model, _identity), do: nil

  @doc "Returns the canonical root-qualified graph-card origin id for one current member."
  @spec origin_id(BuildOrderViewModel.t(), term()) :: String.t() | nil
  def origin_id(%BuildOrderViewModel{} = model, identity) do
    with {:ok, {root_key, _generation}} <- scope(model),
         %Node{key: key, identity: member_identity} <- exact_member(model, identity),
         true <- same_repository?(model.root, member_identity) do
      opaque("build-order-card", {root_key, key})
    else
      _ -> nil
    end
  end

  def origin_id(_model, _identity), do: nil

  @doc "Opens context for one exact current member navigation value."
  @spec open(t(), BuildOrderViewModel.t(), term()) :: t()
  def open(%__MODULE__{status: :closed} = state, %BuildOrderViewModel{} = model, navigation_value) do
    with {:ok, {root_key, generation}} <- scope(model),
         %Node{identity: identity} <- resolve_navigation(model, navigation_value),
         origin when is_binary(origin) <- origin_id(model, identity) do
      state
      |> Map.merge(%{
        status: :open,
        root_key: root_key,
        generation: generation,
        selected: identity,
        history: [],
        origin_id: origin,
        focus_revision: state.focus_revision + 1
      })
      |> rotate_request()
    else
      _ -> state
    end
  end

  def open(%__MODULE__{} = state, _model, _navigation_value), do: state
  def open(_state, _model, _navigation_value), do: new()

  @doc "Replaces the current ticket with one exact member in the same current scope."
  @spec replace(t(), BuildOrderViewModel.t(), term()) :: t()
  def replace(%__MODULE__{status: :open} = state, %BuildOrderViewModel{} = model, navigation_value) do
    with true <- current_scope?(state, model),
         %Node{identity: identity} <- resolve_navigation(model, navigation_value),
         false <- same_identity?(identity, state.selected) do
      state
      |> Map.merge(%{
        selected: identity,
        history: Enum.take([state.selected | state.history], @max_history),
        focus_revision: state.focus_revision + 1
      })
      |> rotate_request()
    else
      _ -> state
    end
  end

  def replace(%__MODULE__{} = state, _model, _navigation_value), do: state
  def replace(_state, _model, _navigation_value), do: new()

  @doc "Returns to the newest surviving exact member in bounded relationship history."
  @spec back(t(), BuildOrderViewModel.t()) :: t()
  def back(%__MODULE__{status: :open} = state, %BuildOrderViewModel{} = model) do
    with true <- current_scope?(state, model),
         {%Node{identity: identity}, remaining} <- next_history(state.history, model) do
      state
      |> Map.merge(%{
        selected: identity,
        history: remaining,
        focus_revision: state.focus_revision + 1
      })
      |> rotate_request()
    else
      _ -> state
    end
  end

  def back(%__MODULE__{} = state, _model), do: state
  def back(_state, _model), do: new()

  @doc "Reconciles an open selection against a current root and planning generation."
  @spec reconcile(t(), BuildOrderViewModel.t()) :: t()
  def reconcile(%__MODULE__{status: :open} = state, %BuildOrderViewModel{} = model) do
    with {:ok, {root_key, generation}} <- scope(model),
         true <- root_key == state.root_key,
         %Node{identity: identity} <- exact_member(model, state.selected) do
      history = surviving_history(state.history, model)

      cond do
        generation == state.generation and history == state.history ->
          state

        generation == state.generation ->
          %{state | selected: identity, history: history}

        true ->
          state
          |> Map.merge(%{generation: generation, selected: identity, history: history})
          |> rotate_request()
      end
    else
      _ -> close(state)
    end
  end

  def reconcile(%__MODULE__{} = state, _model), do: state
  def reconcile(_state, _model), do: new()

  @doc "Closes context and invalidates the current completion token."
  @spec close(t()) :: t()
  def close(%__MODULE__{status: :open} = state) do
    %__MODULE__{
      request_sequence: state.request_sequence + 1,
      focus_revision: state.focus_revision
    }
  end

  def close(%__MODULE__{} = state), do: state
  def close(_state), do: new()

  @doc "Clears open selection during reconnect and invalidates its completion generation."
  @spec reconnect(t()) :: t()
  def reconnect(%__MODULE__{status: :open} = state), do: close(state)
  def reconnect(%__MODULE__{} = state), do: state
  def reconnect(_state), do: new()

  @doc "Checks that delayed base-context data belongs to the exact current request."
  @spec current_completion?(t(), term(), term()) :: boolean()
  def current_completion?(%__MODULE__{status: :open} = state, token, identity) do
    is_binary(token) and token == state.request_token and same_identity?(identity, state.selected)
  end

  def current_completion?(_state, _token, _identity), do: false

  defp rotate_request(%__MODULE__{} = state) do
    sequence = state.request_sequence + 1
    token = opaque("request", {state.root_key, state.generation, TrackerIdentity.github_key(state.selected), sequence})
    %{state | request_sequence: sequence, request_token: token}
  end

  defp resolve_navigation(model, navigation_value) when is_binary(navigation_value) do
    case scope(model) do
      {:ok, {root_key, generation}} ->
        matches =
          Enum.filter(model.nodes, fn
            %Node{key: key, identity: identity} ->
              TrackerIdentity.github_key(identity) == key and
                same_repository?(model.root, identity) and
                navigation_value_for_scope(root_key, generation, key) == navigation_value

            _node ->
              false
          end)

        case matches do
          [%Node{} = node] -> node
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp resolve_navigation(_model, _navigation_value), do: nil

  defp next_history([identity | rest], model) do
    case exact_member(model, identity) do
      %Node{} = node -> {node, rest}
      nil -> next_history(rest, model)
    end
  end

  defp next_history([], _model), do: nil

  defp surviving_history(history, model) do
    history
    |> Enum.filter(&match?(%Node{}, exact_member(model, &1)))
    |> Enum.take(@max_history)
  end

  defp exact_member(model, identity) do
    case TrackerIdentity.github_key(identity) do
      nil ->
        nil

      key ->
        case exact_nodes(model, key) do
          [%Node{} = node] -> node
          _ -> nil
        end
    end
  end

  defp exact_nodes(model, key) do
    Enum.filter(model.nodes, fn
      %Node{key: ^key, identity: identity} -> TrackerIdentity.github_key(identity) == key
      _node -> false
    end)
  end

  defp current_scope?(state, model) do
    case scope(model) do
      {:ok, {root_key, generation}} -> root_key == state.root_key and generation == state.generation
      :error -> false
    end
  end

  defp scope(%BuildOrderViewModel{
         root: %{identity: %TrackerIdentity{} = root, generation: generation},
         generations: %{planning: generation}
       })
       when is_integer(generation) and generation > 0 do
    case TrackerIdentity.github_key(root) do
      nil -> :error
      root_key -> {:ok, {root_key, generation}}
    end
  end

  defp scope(_model), do: :error

  defp navigation_value_for_scope(root_key, generation, key) do
    opaque("member", {root_key, generation, key})
  end

  defp opaque(prefix, value) do
    encoded =
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    OpaqueIdentifier.normalize("#{prefix}-#{encoded}")
  end

  defp same_repository?(%{identity: %TrackerIdentity{} = root}, %TrackerIdentity{} = member) do
    Bounded.same_repository?(root, member)
  end

  defp same_repository?(_root, _member), do: false

  defp same_identity?(left, right) do
    case {TrackerIdentity.github_key(left), TrackerIdentity.github_key(right)} do
      {nil, _right} -> false
      {key, key} -> true
      _different -> false
    end
  end
end
