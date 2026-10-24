defmodule Aiur.Orchestrator.TicketTransition do
  @moduledoc """
  Owns ticket state and marker writes, with caller attribution and outcome evidence.

  The tracker label is authoritative: repeated writes retain adapter semantics.
  GitHub state writes retry local budget holds at the request boundary.
  Errors are returned unchanged. Transport/deadline failures have unknown outcomes.
  `tracker:` names the facade-shaped module to call (default `Aiur.Tracker`); the
  build queue passes its injected tracker so its writes are attributed here too.
  """

  require Logger
  alias Aiur.GitHub.{Config, Labels}
  alias Aiur.LandingWatch.Journal
  alias Aiur.Orchestrator.{AgentTeardown, CiLifecycle, Effect, HumanReview, PauseResume, RetryEngine, State}
  alias Aiur.Tracker

  @doc "Apply requests in order, before the caller reads transition output."
  @spec apply_effects(State.t(), [Effect.t()]) :: State.t()
  def apply_effects(state, effects) do
    Enum.reduce(effects, state, fn effect, current ->
      case apply_effect(current, effect) do
        {_result, %State{} = next} -> next
        %State{} = next -> next
      end
    end)
  end

  @doc "Apply one effect, preserving resume/reactivate outcomes for dependent actions."
  @spec apply_effect(State.t(), Effect.t()) :: State.t() | {term(), State.t()}
  def apply_effect(state, {:terminate, id, cleanup?}), do: AgentTeardown.terminate_running_issue(state, id, cleanup?)
  def apply_effect(state, {:resume_paused, entry, operator?}), do: PauseResume.resume_paused_issue(state, entry, operator?)
  def apply_effect(state, {:reactivate, entry}), do: PauseResume.reactivate_issue(state, entry)
  def apply_effect(state, {:transition_control, entry, status, reason}), do: PauseResume.transition_control_status(state, entry, status, reason)
  def apply_effect(state, {:preserve_on_external_error, issue}), do: RetryEngine.preserve_running_issue_on_external_error(state, issue)
  def apply_effect(state, {:pause_for_ci_wait, issue}), do: CiLifecycle.pause_issue_for_ci_wait(state, issue)
  def apply_effect(state, {:maybe_deactivate_human_review, issue}), do: HumanReview.maybe_deactivate_human_review_issue(state, issue)

  @spec write_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_state(issue_id, to_state, opts) do
    writer = Keyword.fetch!(opts, :writer)
    true = is_atom(writer) and not is_nil(writer)
    tracker = Keyword.get(opts, :tracker, Tracker)

    adapter_opts = Keyword.drop(opts, [:writer, :identifier, :tracker, :reason_modifiers, :label_prefix, :current_labels])
    result = with_writer(writer, fn -> tracker.update_issue_state(issue_id, to_state, adapter_opts) end)

    record(issue_id, :state, to_state, writer, opts, result)

    if result == :ok and Keyword.has_key?(opts, :reason_modifiers) do
      case write_reason_modifiers(issue_id, opts[:reason_modifiers], opts) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("ticket reason label update failed: issue_id=#{issue_id} reason=#{inspect(reason)}")
      end
    end

    result
  end

  @ci_reason_modifiers ~w(merge-queued ci-red)

  @doc "Replaces the CI-owned reason labels (merge-queued, ci-red) alongside the workflow state."
  @spec write_reason_modifiers(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def write_reason_modifiers(issue_id, suffixes, opts) when is_binary(issue_id) and is_list(suffixes) do
    writer = Keyword.fetch!(opts, :writer)
    true = is_atom(writer) and not is_nil(writer)
    tracker = Keyword.get(opts, :tracker, Tracker)
    prefix = Keyword.get(opts, :label_prefix, Config.label_prefix())

    desired = Enum.uniq(suffixes)

    if Enum.any?(desired, &(&1 not in @ci_reason_modifiers)) do
      {:error, {:invalid_reason_modifiers, desired}}
    else
      # Only the CI-owned reasons are swapped; blocked/paused/retrying belong to other writers.
      owned = Enum.map(@ci_reason_modifiers, &"#{prefix}:#{&1}")
      desired_labels = Enum.map(desired, &"#{prefix}:#{&1}")
      {additions, removals} = reason_label_changes(desired_labels, owned -- desired_labels, Keyword.get(opts, :current_labels))

      write_reason_modifier_labels(issue_id, additions, removals, tracker, writer, opts)
    end
  end

  @doc "Adds or removes one known runtime reason label without changing the workflow state."
  @spec write_reason_modifier(String.t(), :add | :remove, String.t(), keyword()) :: :ok | {:error, term()}
  def write_reason_modifier(issue_id, action, suffix, opts) when action in [:add, :remove] do
    if Labels.reason_modifier_suffix?(suffix) do
      prefix = Keyword.get(opts, :label_prefix, Config.label_prefix())
      write_marker(issue_id, action, "#{prefix}:#{suffix}", opts)
    else
      {:error, {:invalid_reason_modifier, suffix}}
    end
  end

  @doc "Returns a canonical prefixed label for a known reason suffix."
  @spec reason_modifier_label(String.t()) :: String.t() | nil
  def reason_modifier_label(suffix) do
    if Labels.reason_modifier_suffix?(suffix), do: "#{Config.label_prefix()}:#{suffix}"
  end

  @doc "Maps a runtime cause to its canonical reason suffix."
  @spec runtime_reason_modifier(term()) :: String.t() | nil
  def runtime_reason_modifier(reason), do: Labels.runtime_reason_modifier(reason)

  @doc "Returns present runtime labels in the canonical vocabulary order."
  @spec present_runtime_labels(term(), String.t()) :: [String.t()]
  def present_runtime_labels(labels, prefix), do: Labels.present_runtime_labels(labels, prefix)

  @doc "Returns tracker labels plus labels inferred from live runtime causes."
  @spec runtime_labels(term(), [term()], String.t()) :: [String.t()]
  def runtime_labels(labels, causes, prefix), do: Labels.runtime_labels(labels, causes, prefix)

  @doc "Removes transient runtime reasons, preserving the dependency blocker marker."
  @spec clear_transient_reason_modifiers(String.t(), keyword()) :: :ok | {:error, term()}
  def clear_transient_reason_modifiers(issue_id, opts) do
    retained = ["blocked", "body-fix"]
    removals = Labels.reason_modifier_suffixes() -- retained
    prefix = Keyword.get(opts, :label_prefix, Config.label_prefix())
    labels = Enum.map(removals, &"#{prefix}:#{&1}")
    present = Keyword.get(opts, :current_labels)
    labels = if is_list(present), do: Enum.filter(labels, &(&1 in present)), else: labels
    if labels == [], do: :ok, else: clear_transient_labels(issue_id, labels, opts)
  end

  defp clear_transient_labels(issue_id, labels, opts) do
    writer = Keyword.fetch!(opts, :writer)
    tracker = Keyword.get(opts, :tracker, Tracker)
    write_markers(issue_id, :remove, labels, Keyword.put(opts, :writer, writer) |> Keyword.put(:tracker, tracker))
  end

  @spec write_marker(String.t(), :add | :remove, String.t(), keyword()) :: :ok | {:error, term()}
  def write_marker(issue_id, action, label, opts) when action in [:add, :remove] do
    writer = Keyword.fetch!(opts, :writer)
    true = is_atom(writer) and not is_nil(writer)
    tracker = Keyword.get(opts, :tracker, Tracker)
    result = with_writer(writer, fn -> if action == :add, do: tracker.add_label(issue_id, label), else: tracker.remove_label(issue_id, label) end)
    maybe_record_pause_writer(issue_id, action, label, writer, result, opts)
    record(issue_id, action, label, writer, opts, result)
    result
  end

  defp maybe_record_pause_writer(issue_id, action, label, :approval_pause, :ok, opts)
       when is_binary(issue_id) and is_binary(label) do
    if String.ends_with?(label, ":paused") do
      recorded_writer = if action == :add, do: :approval_pause, else: nil

      case Journal.record_pause_writer(issue_id, recorded_writer, Keyword.get(opts, :landing_watch_journal_opts, [])) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("ticket pause provenance could not be recorded: issue_id=#{issue_id} reason=#{inspect(reason)}")
      end
    end
  end

  defp maybe_record_pause_writer(_issue_id, _action, _label, _writer, _result, _opts), do: :ok

  # With the tracker's current labels known, write only the difference; otherwise write all.
  defp reason_label_changes(additions, removals, current) when is_list(current) do
    present = MapSet.new(current, &String.downcase/1)
    {Enum.reject(additions, &MapSet.member?(present, &1)), Enum.filter(removals, &MapSet.member?(present, &1))}
  end

  defp reason_label_changes(additions, removals, _current), do: {additions, removals}

  defp write_reason_modifier_labels(issue_id, additions, removals, tracker, writer, opts) do
    marker_opts = Keyword.put(opts, :writer, writer) |> Keyword.put(:tracker, tracker)

    case write_markers(issue_id, :add, additions, marker_opts) do
      :ok -> write_markers(issue_id, :remove, removals, marker_opts)
      error -> error
    end
  end

  defp write_markers(issue_id, action, labels, opts) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case write_marker(issue_id, action, label, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec write_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_comment(issue_id, body, opts) do
    writer = Keyword.fetch!(opts, :writer)
    tracker = Keyword.get(opts, :tracker, Tracker)
    result = with_writer(writer, fn -> tracker.create_comment(issue_id, body) end)
    record(issue_id, :comment, body, writer, opts, result)
    result
  end

  defp with_writer(writer, fun) do
    previous = Process.get(:aiur_ticket_writer)
    Process.put(:aiur_ticket_writer, writer)

    try do
      fun.()
    after
      if previous == nil, do: Process.delete(:aiur_ticket_writer), else: Process.put(:aiur_ticket_writer, previous)
    end
  end

  defp record(issue_id, action, to, writer, opts, result) do
    meta = %{issue_id: issue_id, identifier: opts[:identifier], action: action, to: to, expected: opts[:expected_state], writer: writer, outcome: outcome(result)}
    # ponytail: daemon/CLI logs are durable evidence; IssueLog needs a ticket observation before subscribing.
    Logger.info("ticket_transition issue_id=#{issue_id} action=#{action} to=#{inspect(to)} expected=#{inspect(meta.expected)} writer=#{writer} outcome=#{inspect(meta.outcome)}")
    :telemetry.execute([:aiur, :ticket_transition], %{}, meta)
  end

  defp outcome(:ok), do: :ok
  defp outcome({:error, {:github, kind, _}}) when kind in [:timeout, :transport, :dns, :tls], do: :unknown
  defp outcome({:error, reason}) when reason in [:timeout, :deadline_exceeded], do: :unknown
  defp outcome(result), do: result
end
