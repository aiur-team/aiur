defmodule Aiur.StartTrigger do
  @moduledoc "Pure prerequisite stage policy. Fresh evidence is required even for final stages."
  alias Aiur.StartTrigger.Evidence
  @triggers [:issue_closed, :pr_merged, :pr_approved, :pr_ci_green, :pr_opened]
  @type trigger :: :issue_closed | :pr_merged | :pr_approved | :pr_ci_green | :pr_opened
  @type verdict :: {:satisfied, :final | :optimistic} | :pending | {:unknown, atom()} | {:failed, atom()}

  @spec triggers() :: [trigger()]
  def triggers, do: @triggers

  @spec parse(term()) :: {:ok, trigger()} | {:error, :invalid_start_trigger}
  def parse(value) do
    case Enum.find(@triggers, &(value == &1 or value == Atom.to_string(&1))) do
      nil -> {:error, :invalid_start_trigger}
      trigger -> {:ok, trigger}
    end
  end

  @spec satisfies?(trigger() | nil, trigger()) :: boolean()
  def satisfies?(nil, _trigger), do: false
  def satisfies?(stage, trigger), do: rank(stage) >= rank(trigger)

  @spec stage(Evidence.t() | nil) :: trigger() | nil
  def stage(nil), do: nil
  def stage(%Evidence{issue_open?: false, state_reason: "completed"}), do: :issue_closed

  def stage(%Evidence{} = evidence) do
    label_stage = label_stage(evidence.state_label)
    stages = [label_stage, evidence.stage_reached, if(evidence.pr == :merged, do: :pr_merged)]
    Enum.max_by(stages, &rank/1)
  end

  @doc "Reports a reached final stage; use edge_verdict/3 to validate freshness and failure evidence."
  @spec final?(Evidence.t() | nil) :: boolean()
  def final?(evidence), do: satisfies?(stage(evidence), :pr_merged)

  @spec edge_verdict(trigger(), Evidence.t() | nil, keyword()) :: verdict()
  def edge_verdict(trigger, evidence, opts) do
    cond do
      Keyword.get(opts, :cyclic, false) -> {:unknown, :cyclic}
      evidence && evidence.unavailable_reason -> {:unknown, evidence.unavailable_reason}
      stale?(evidence, opts) -> {:unknown, :stale}
      true -> classify(trigger, evidence, opts)
    end
  end

  defp stale?(nil, _opts), do: true
  defp stale?(%Evidence{issue_open?: :unknown}, _opts), do: true
  defp stale?(%Evidence{observed_at_ms: nil}, _opts), do: true

  defp stale?(%Evidence{observed_at_ms: observed}, opts) do
    now = Keyword.fetch!(opts, :now_ms)
    observed > now or now - observed > Keyword.fetch!(opts, :max_age_ms)
  end

  defp classify(_trigger, %Evidence{issue_open?: false, state_reason: "completed"}, _opts), do: {:satisfied, :final}

  defp classify(_trigger, %Evidence{issue_open?: false, state_reason: "not_planned"}, opts) do
    if Keyword.get(opts, :not_planned, :fail) == :satisfy, do: {:satisfied, :final}, else: {:failed, :not_planned}
  end

  defp classify(_trigger, %Evidence{issue_open?: false, state_reason: "duplicate"}, _opts), do: {:unknown, :duplicate}
  defp classify(_trigger, %Evidence{issue_open?: false}, _opts), do: {:unknown, :closed_reason}

  defp classify(trigger, evidence, _opts) do
    cond do
      evidence.state_label == "error" -> {:failed, :agent_error}
      evidence.pr == :closed_unmerged -> {:failed, :pr_closed_unmerged}
      satisfies?(stage(evidence), trigger) -> {:satisfied, if(final?(evidence), do: :final, else: :optimistic)}
      true -> :pending
    end
  end

  defp label_stage("done"), do: :pr_merged
  defp label_stage("merging"), do: :pr_approved
  defp label_stage(label) when label in ["human-review", "rework"], do: :pr_ci_green
  defp label_stage("ci-wait"), do: :pr_opened
  defp label_stage(_), do: nil
  defp rank(nil), do: -1
  defp rank(stage), do: length(@triggers) - Enum.find_index(@triggers, &(&1 == stage))
end
