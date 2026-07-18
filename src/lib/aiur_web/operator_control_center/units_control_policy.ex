defmodule AiurWeb.OperatorControlCenter.UnitsControlPolicy do
  @moduledoc """
  Renderer-independent policy for pause/resume unit controls (DASH-005).

  Truth is DASH-004: a control shows *applied* only from control-lifecycle
  evidence, never from the requested value or a client-local row mutation. This
  module owns three pure decisions and carries no side effects:

    * `affordance/2` — which control a row presents *before* invocation, from row
      facts plus any in-flight request state.
    * `recheck/2` — whether an invocation is still eligible at request time, from
      a fresh DASH-004 capability projection. Mount-time state is insufficient;
      the caller rechecks server-side authorization, writable mode, typed
      identity/generation, eligibility, and capability at invocation.
    * `presentation/1` — how a normalized control state renders (label, tone,
      accessible text, retry guidance).

  Read-only, unauthenticated, unsupported, and request-only states are visibly
  distinct and never masquerade as an enabled applied control.
  """

  alias Aiur.TrackerIdentity

  @type action :: :pause | :resume

  @typedoc "Presented affordance for one row before invocation."
  @type affordance :: %{
          action: action() | nil,
          state: :enabled | :pending | :disabled,
          reason: atom() | nil,
          pending_action: action() | nil
        }

  @typedoc """
  Normalized per-unit control state the LiveView holds. `status` is either a
  DASH-004 lifecycle status (`:requested`, `:accepted`, `:applied`, `:rejected`,
  `:expired`) or a synthetic pre-invocation gate result (`:request_only`,
  `:unsupported`, `:state_changed`, `:already_pending`, `:error`).
  """
  @type control_state :: %{
          required(:action) => action(),
          required(:status) => atom(),
          optional(:rejection) => map() | nil,
          optional(:request_id) => pos_integer() | nil,
          optional(:identifier) => String.t()
        }

  @in_flight [:requested, :accepted]

  @doc """
  The control a row presents before invocation. An in-flight request (its own
  `control_state`) always wins so repeated activation is disabled while pending.
  """
  @spec affordance(map(), control_state() | nil) :: affordance()
  def affordance(row, control_state) when is_map(row) do
    case control_state do
      %{status: status, action: action} when status in @in_flight ->
        %{action: nil, state: :pending, reason: nil, pending_action: action}

      _settled ->
        base_affordance(row)
    end
  end

  def affordance(_row, _control_state),
    do: %{action: nil, state: :disabled, reason: :unavailable, pending_action: nil}

  defp base_affordance(row) do
    cond do
      is_nil(identifier(row)) -> disabled(:no_identity)
      terminal?(row) -> disabled(:terminal)
      replacement_boundary?(row) -> disabled(:replaced_generation)
      remote_control?(row) -> disabled(:remote_control)
      retrying?(row) -> disabled(:retrying)
      merging?(row) -> disabled(:merging)
      paused?(row) -> enabled(:resume)
      running_working?(row) -> enabled(:pause)
      queued?(row) -> disabled(:queued)
      true -> disabled(:unavailable)
    end
  end

  defp enabled(action), do: %{action: action, state: :enabled, reason: nil, pending_action: nil}
  defp disabled(reason), do: %{action: nil, state: :disabled, reason: reason, pending_action: nil}

  @doc """
  Invocation-time eligibility gate over a fresh DASH-004 capability projection
  (`%{unit_control:, status:, pending_control:}`). Returns `:ok` only when the
  worker confirms application, no control is already pending, and the
  authoritative state still matches the requested action. A concurrent state or
  generation change resolves truthfully to `:state_changed` rather than
  targeting a replacement unit.
  """
  @spec recheck(map(), action()) :: :ok | {:error, atom()}
  def recheck(capabilities, action) when is_map(capabilities) and action in [:pause, :resume] do
    cap = Map.get(capabilities, :unit_control)
    status = Map.get(capabilities, :status)
    pending = Map.get(capabilities, :pending_control)

    cond do
      not is_nil(pending) -> {:error, :already_pending}
      cap == :unsupported -> {:error, :unsupported}
      cap == :request_only -> {:error, :request_only}
      not action_matches_status?(action, status) -> {:error, :state_changed}
      cap == :confirmed -> :ok
      true -> {:error, :ineligible}
    end
  end

  def recheck(_capabilities, _action), do: {:error, :ineligible}

  defp action_matches_status?(:pause, :working), do: true
  defp action_matches_status?(:resume, :paused), do: true
  defp action_matches_status?(_action, _status), do: false

  @doc """
  Normalizes a `{:error, reason}` control failure into a settled control state
  the renderer can present. Owner rejections carry a DASH-004 rejection class.
  """
  @spec settle_error(action(), term(), String.t() | nil) :: control_state()
  def settle_error(action, {:control_rejected, %{class: _class} = rejection}, identifier) do
    %{action: action, status: :rejected, rejection: rejection, identifier: identifier}
  end

  def settle_error(action, {:control_expired, expiry}, identifier) do
    %{action: action, status: :expired, rejection: expiry, identifier: identifier}
  end

  def settle_error(action, reason, identifier) when is_atom(reason) do
    %{action: action, status: reason, identifier: identifier}
  end

  def settle_error(action, reason, identifier) do
    %{action: action, status: :error, rejection: %{class: reason}, identifier: identifier}
  end

  @doc """
  Merges an incoming DASH-004 lifecycle projection into the tracked state for a
  unit, but only when it corresponds to the tracked request. A newer generation
  or a mismatched request is ignored so stale intent never overwrites truth.
  """
  @spec apply_lifecycle(control_state() | nil, map()) :: control_state() | nil
  def apply_lifecycle(nil, _payload), do: nil

  def apply_lifecycle(%{} = tracked, %{} = payload) do
    if correlated?(tracked, payload) do
      %{
        action: Map.get(payload, :action, tracked.action),
        status: Map.get(payload, :status),
        rejection: Map.get(payload, :rejection),
        request_id: Map.get(payload, :request_id, Map.get(tracked, :request_id)),
        identifier: Map.get(tracked, :identifier)
      }
    else
      tracked
    end
  end

  # A tracked pause returns its request_id up front; a resume binds it on the
  # first correlated event. Match on request_id when both are known, else on the
  # action for the still-unbound resume case.
  defp correlated?(tracked, payload) do
    same_action = Map.get(tracked, :action) == Map.get(payload, :action)
    tracked_rid = Map.get(tracked, :request_id)
    payload_rid = Map.get(payload, :request_id)

    cond do
      not is_nil(tracked_rid) -> tracked_rid == payload_rid
      same_action -> true
      true -> false
    end
  end

  @doc "Whether a settled state still permits a fresh activation of the row."
  @spec settled?(control_state() | nil) :: boolean()
  def settled?(nil), do: true
  def settled?(%{status: status}), do: status not in @in_flight
  def settled?(_state), do: true

  @doc """
  Renders a normalized control state for display: a short status label, a tone
  for non-color-only feedback, accessible announcement text, and whether a
  retry is offered.
  """
  @spec presentation(control_state()) :: %{
          label: String.t(),
          tone: atom(),
          announce: String.t(),
          retry?: boolean()
        }
  def presentation(%{status: :requested, action: action}),
    do: present(pending_label(action, "requested"), :pending, false)

  def presentation(%{status: :accepted, action: action}),
    do: present(pending_label(action, "accepted, applying"), :pending, false)

  def presentation(%{status: :applied, action: action}),
    do: present(applied_label(action), :applied, false)

  def presentation(%{status: :rejected} = state), do: rejection_presentation(state)

  def presentation(%{status: :expired, action: action}),
    do: present("#{verb(action)} timed out — retry", :error, true)

  def presentation(%{status: :request_only, action: action}),
    do: present("#{verb(action)} is request-only — not applied", :warning, false)

  def presentation(%{status: :unsupported, action: action}),
    do: present("#{verb(action)} unsupported on this worker", :warning, false)

  def presentation(%{status: :state_changed, action: action}),
    do: present("Unit state changed — #{String.downcase(verb(action))} canceled", :warning, false)

  def presentation(%{status: :already_pending, action: action}),
    do: present("A #{String.downcase(verb(action))} is already pending", :pending, false)

  def presentation(%{action: action}),
    do: present("#{verb(action)} could not be applied — retry", :error, true)

  defp rejection_presentation(%{action: action} = state) do
    case rejection_class(state) do
      :superseded -> present("Superseded by a newer request", :warning, false)
      :already_in_state -> present(applied_label(action), :applied, false)
      :unsupported -> present("#{verb(action)} unsupported on this worker", :warning, false)
      :stale_generation -> present("Unit changed generation — #{String.downcase(verb(action))} canceled", :warning, false)
      _class -> present("#{verb(action)} rejected — retry", :error, true)
    end
  end

  defp rejection_class(state) do
    get_in(state, [:rejection, Access.key(:class)]) || get_in(state, [:rejection, Access.key("class")])
  end

  defp present(label, tone, retry?), do: %{label: label, tone: tone, announce: label, retry?: retry?}

  defp pending_label(action, phase), do: "#{verb(action)} #{phase}…"
  defp applied_label(:pause), do: "Paused"
  defp applied_label(:resume), do: "Resumed"
  defp applied_label(_action), do: "Applied"

  defp verb(:pause), do: "Pause"
  defp verb(:resume), do: "Resume"
  defp verb(_action), do: "Control"

  @doc "Human copy for a disabled affordance reason, for accessible titles."
  @spec disabled_reason(atom()) :: String.t()
  def disabled_reason(:no_identity), do: "No typed identity — control unavailable"
  def disabled_reason(:terminal), do: "Unit is in a terminal state"
  def disabled_reason(:replaced_generation), do: "Superseded by a newer generation"
  def disabled_reason(:remote_control), do: "Under Remote Control"
  def disabled_reason(:retrying), do: "Unit is retrying"
  def disabled_reason(:merging), do: "Unit is merging"
  def disabled_reason(:queued), do: "Unit is not running"
  def disabled_reason(_reason), do: "Control unavailable"

  # --- row fact readers -----------------------------------------------------

  @spec identifier(map()) :: String.t() | nil
  def identifier(%{identity: %TrackerIdentity{identifier: identifier}}) when is_binary(identifier),
    do: identifier

  def identifier(_row), do: nil

  defp terminal?(row), do: Map.get(row, :terminal?) == true and not replacement_boundary?(row)
  defp replacement_boundary?(row), do: Map.get(row, :replacement_boundary?) == true

  defp remote_control?(row) do
    Map.get(row, :lifecycle) == :remote_control or runtime_bucket(row) == :remote_control or
      work_state(row) == :remote_control
  end

  defp paused?(row) do
    running_ish?(row) and
      (work_state(row) in [:paused, :sleeping] or get_in(row, [:runtime, :tracker_paused?]) == true)
  end

  defp running_working?(row) do
    runtime_bucket(row) == :running and work_state(row) in [:working, :allocated]
  end

  defp running_ish?(row) do
    runtime_bucket(row) == :running or work_state(row) in [:working, :allocated, :paused, :sleeping]
  end

  defp retrying?(row) do
    runtime_bucket(row) == :retrying or Map.get(row, :lifecycle) == :retrying or
      work_state(row) == :retrying
  end

  defp merging?(row), do: Map.get(row, :lifecycle) == :merging or work_state(row) == :merging

  defp queued?(row) do
    runtime_bucket(row) == :queued or Map.get(row, :lifecycle) in [:queued, :waiting]
  end

  # Mirror UnitsPolicy's flat-key fallback so both policies classify a row the
  # same way regardless of which row shape it carries.
  defp runtime_bucket(row), do: get_in(row, [:runtime, :bucket]) || Map.get(row, :runtime_bucket)
  defp work_state(row), do: get_in(row, [:runtime, :work_state]) || Map.get(row, :work_state)
end
