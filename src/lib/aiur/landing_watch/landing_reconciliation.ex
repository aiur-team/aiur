defmodule Aiur.LandingWatch.LandingReconciliation do
  @moduledoc false

  alias Aiur.GitHub.CiReadiness
  alias Aiur.LandingWatch.{Classifier, LocalRead, MergeGroups, MergeQueueWatchdog}

  @spec process([map()], keyword(), ([map()], keyword() -> term())) :: :ok | {:error, term()}
  def process(observations, opts, process_all_fun) do
    opts = poll_required_checks(observations, opts)
    result = process_all_fun.(observations, opts)
    evidence_ref = make_ref()
    evidence_owner = self()

    reconcile_opts =
      Keyword.put(opts, :merge_group_evidence_fun, fn runs, fresh_observations, classifier_opts ->
        if Keyword.get(classifier_opts, :merge_group_failure_evidence_prepared, false) do
          send(evidence_owner, {:merge_group_evidence, evidence_ref, %{runs: runs, observations: fresh_observations, classifier_opts: classifier_opts}})
        end

        :ok
      end)

    reconcile = Keyword.get(opts, :queue_reconcile_fun, &MergeGroups.cancel_stale/2).(observations, reconcile_opts)
    # MergeGroups invokes the callback after MergeGroupFailureProcessor has prepared
    # main-branch and flake evidence; do not consume its earlier, incomplete form.
    evidence = read_evidence(evidence_ref)

    watchdog_opts =
      opts
      |> Keyword.merge(evidence[:classifier_opts] || [])
      |> Keyword.put(:completed_merge_group_runs, evidence[:runs] || [])
      |> Keyword.put(:all_observations, evidence[:observations] || observations)

    MergeQueueWatchdog.after_reconcile(result, reconcile, observations, watchdog_opts)
  end

  defp read_evidence(ref) do
    receive do
      {:merge_group_evidence, ^ref, evidence} -> evidence
    after
      0 -> %{}
    end
  end

  defp poll_required_checks(observations, opts) do
    if Enum.any?(observations, fn observation -> Classifier.approved_at_head?(Map.get(observation, :raw, %{})) end) do
      required_checks = Keyword.get(opts, :required_checks_fun, &CiReadiness.fetch_required_checks/1)
      Keyword.put(opts, :required_checks_snapshot, LocalRead.run(required_checks, [opts], opts))
    else
      opts
    end
  end
end
