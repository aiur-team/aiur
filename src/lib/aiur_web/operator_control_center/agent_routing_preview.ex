defmodule AiurWeb.OperatorControlCenter.AgentRoutingPreview do
  @moduledoc """
  Predicts which agent would pick a ticket up, using the dispatcher's own rules.

  The preview never reimplements routing. It builds the `Aiur.Issue` the
  dispatcher would build from the ticket's labels and asks `Aiur.CodingAgent`
  the same questions `Aiur.AgentRunner.SessionLifecycle` asks at dispatch, so a
  routing table the operator edits in `agent.routing` is reflected here without
  a second copy of the truth table drifting behind it.

  Every configuration read can fail — a daemon booted without settings has no
  `agent.priority` at all — so an unreadable config yields an explicitly
  unavailable preview rather than a confident wrong answer.
  """

  alias Aiur.{CodingAgent, Config, Issue}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.StatePolicy

  @complexities 1..5

  @type t :: %{
          available?: boolean(),
          complexity: pos_integer() | nil,
          backend: String.t() | nil,
          session_backend: String.t() | nil,
          model: String.t() | nil,
          resolved_model: String.t() | nil,
          effort: String.t() | nil,
          remote?: boolean(),
          labels: [String.t()]
        }

  @doc """
  Returns the routing the dispatcher would apply to a ticket carrying `labels`.

  `model` is the requested model and may be `nil`, meaning "the backend's own
  default"; `resolved_model` is what that resolves to for the session backend.
  """
  @spec preview([String.t()]) :: t()
  def preview(labels) when is_list(labels) do
    issue = issue(labels)
    backend = CodingAgent.backend_for(issue)
    remote? = remote?(issue, backend)
    session_backend = session_backend(backend, remote?)
    model = CodingAgent.model_for(issue)

    %{
      available?: true,
      complexity: CodingAgent.complexity_level(issue),
      backend: backend,
      session_backend: session_backend,
      model: model,
      resolved_model: CodingAgent.resolve_model(session_backend, model),
      effort: CodingAgent.effort_for(issue),
      remote?: remote?,
      labels: normalize_labels(labels)
    }
  rescue
    _error -> unavailable(labels)
  catch
    _kind, _reason -> unavailable(labels)
  end

  def preview(_labels), do: preview([])

  @doc """
  The choices the operator may pick from when overriding the preview.

  Backends come from the dispatchable set rather than the whole registry: a
  backend that is not enabled in `agent.backend_configs` (or listed in
  `agent.priority`) could never be dispatched, so offering it would promise
  something the daemon cannot honour.
  """
  @spec options(String.t() | nil) :: %{backends: [String.t()], models: [String.t()], efforts: [String.t()], complexities: [pos_integer()]}
  def options(backend) do
    backends = dispatchable_backends()
    backend = if backend in backends, do: backend, else: List.first(backends)

    %{
      backends: backends,
      models: safe(fn -> CodingAgent.seedable_models(backend) end, []),
      efforts: offerable_efforts(backend),
      complexities: Enum.to_list(@complexities)
    }
  end

  # A backend's effort vocabulary is wider than the override-label vocabulary —
  # codex accepts "none", which has no `model:none` override label. Offering it
  # would write a label `effort_for/1` ignores and `family/1` misfiles as a
  # model tag (so it would not even reconcile against the next selection),
  # which is the same silent discard this modal exists to avoid. Only offer
  # efforts that survive the round trip to dispatch.
  defp offerable_efforts(backend) do
    labels = safe(fn -> CodingAgent.override_effort_labels() end, [])

    safe(fn -> CodingAgent.efforts(backend) end, [])
    |> Enum.filter(&("model:#{&1}" in labels))
  end

  @doc """
  Clamps an operator-supplied selection to values the daemon can actually honour.

  Every field arrives from a browser form, so none of it is trusted: a backend
  outside the dispatchable set, a model or effort outside the chosen backend's
  vocabulary, or a complexity outside `1..5` would otherwise be formatted into a
  tracker label verbatim, and GitHub creates any label it is handed.
  """
  @spec normalize_selection(map()) :: map()
  def normalize_selection(selection) when is_map(selection) do
    options = options(nil)
    backend = member(Map.get(selection, :backend), options.backends)
    backend_options = options(backend)

    %{
      backend: backend,
      model: if(backend, do: member(Map.get(selection, :model), backend_options.models)),
      effort: if(backend, do: member(Map.get(selection, :effort), backend_options.efforts)),
      complexity: complexity(Map.get(selection, :complexity))
    }
  end

  def normalize_selection(_selection), do: %{backend: nil, model: nil, effort: nil, complexity: nil}

  @doc """
  The label changes that express one confirmed selection on the tracker.

  Returns `%{add: [...], remove: [...]}`. Only labels the tracker vocabulary
  already defines are produced: the configured first active-state label — which
  is what actually makes a ticket dispatchable — plus a `complexity:N` tag, the
  `model:<backend>` override, and an optional `model:<effort>` override.

  Labels are reconciled, not appended. `CodingAgent.complexity_level/1` takes the
  *highest* `complexity:N` label and the model/effort overrides take the *first*
  match, so adding a second label of either family beside an existing one is at
  best a no-op and at worst nondeterministic. Every label this selection replaces
  is therefore removed first.
  """
  @spec plan(map(), [String.t()]) :: %{add: [String.t()], remove: [String.t()]}
  def plan(selection, existing_labels \\ [])

  def plan(selection, existing_labels) when is_map(selection) do
    existing = normalize_labels(existing_labels)

    add =
      [
        state_label(),
        complexity_label(Map.get(selection, :complexity)),
        backend_label(Map.get(selection, :backend), Map.get(selection, :model)),
        effort_label(Map.get(selection, :effort))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{add: add -- existing, remove: Enum.filter(existing, &replaced?(&1, add))}
  end

  def plan(_selection, _existing_labels), do: %{add: [], remove: []}

  # Only the families this selection actually writes are reconciled; an unrelated
  # label an operator put on the ticket is never removed on their behalf.
  defp replaced?(label, add) do
    case family(label) do
      :other -> false
      family -> Enum.any?(add, &(&1 != label and family(&1) == family))
    end
  end

  defp family("complexity:" <> _rest), do: :complexity
  defp family("model:" <> _spec = label), do: if(label in effort_labels(), do: :effort, else: :model)
  defp family(_label), do: :other

  defp effort_labels, do: safe(fn -> CodingAgent.override_effort_labels() end, [])

  # The active-state label is what the orchestrator's candidate poll selects on,
  # so without it "add an agent" would leave the ticket exactly as undispatchable
  # as it was. Non-GitHub trackers have no such label vocabulary here.
  defp state_label do
    case Config.active_states() do
      [state | _rest] when is_binary(state) -> StatePolicy.state_label(GitHubConfig.label_prefix(), state)
      _states -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp member(value, options) when is_binary(value), do: if(value in options, do: value)
  defp member(_value, _options), do: nil

  defp complexity(complexity) when is_integer(complexity) and complexity in @complexities, do: complexity
  defp complexity(_complexity), do: nil

  defp complexity_label(complexity) when is_integer(complexity) and complexity in @complexities,
    do: "complexity:#{complexity}"

  defp complexity_label(_complexity), do: nil

  defp backend_label(backend, model) when is_binary(backend) do
    case model do
      model when is_binary(model) and model != "" -> "model:#{backend}-#{model}"
      _default -> "model:#{backend}"
    end
  end

  defp backend_label(_backend, _model), do: nil

  defp effort_label(effort) when is_binary(effort) and effort != "", do: "model:#{effort}"
  defp effort_label(_effort), do: nil

  defp issue(labels) do
    %Issue{id: "preview", identifier: "preview", labels: normalize_labels(labels)}
  end

  # Tracker labels are compared case-insensitively everywhere downstream; the
  # normalizer that builds real issues downcases, so the preview must too or a
  # `Complexity:3` label would route differently here than at dispatch.
  defp normalize_labels(labels) do
    labels
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp remote?(issue, backend) do
    (CodingAgent.remote_control_forced?(issue) or CodingAgent.routing_remote?(issue) or
       safe(fn -> Config.agent_remote_control?() end, false)) and CodingAgent.remote_control?(backend)
  end

  # Mirrors `SessionLifecycle.remote_session_backend/2`: remote control runs the
  # Claude REPL backend, which has its own effort vocabulary.
  defp session_backend("claude", true), do: "claude-repl"
  defp session_backend(backend, _remote?), do: backend

  defp dispatchable_backends do
    safe(fn -> CodingAgent.dispatchable_backends(Config.agent_backend_configs()) end, [])
  end

  defp unavailable(labels) do
    %{
      available?: false,
      complexity: nil,
      backend: nil,
      session_backend: nil,
      model: nil,
      resolved_model: nil,
      effort: nil,
      remote?: false,
      labels: normalize_labels(labels)
    }
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end
end
