defmodule Aiur.MainWatch.State do
  @moduledoc "Pure transitions and seven-day inherited-failure evidence for base CI."
  @retention_ms 7 * 24 * 60 * 60 * 1_000
  @passing ~w(success neutral skipped)
  @failing ~w(failure timed_out action_required startup_failure stale cancelled)

  @spec new() :: map()
  def new do
    %{status: :unknown, sha: nil, last_green_sha: nil, red_since: nil, completed_at: nil, event: nil, emitted_signatures: [], history: []}
  end

  @spec observe(map(), map(), integer()) :: {map(), [{String.t(), map()}]}
  def observe(state, observation, now) do
    state = expire(state, now)

    if complete?(observation) do
      state = remember(state, observation)
      transition(state, observation)
    else
      {state, []}
    end
  end

  @spec record_history(map(), map(), integer()) :: map()
  def record_history(state, observation, now) do
    state = expire(state, now)
    state = if complete?(observation), do: remember(state, observation), else: state
    green = state.history |> Enum.filter(&Enum.all?(&1.checks, fn check -> check.conclusion in @passing end)) |> List.last()
    if green, do: %{state | last_green_sha: green.sha}, else: state
  end

  @spec inherited?(map(), String.t(), String.t()) :: :inherited | :not_inherited | :unknown
  def inherited?(state, name, merge_base) do
    inherited?(state, name, merge_base, state.history |> Enum.map(& &1.sha) |> Enum.reverse())
  end

  @spec inherited?(map(), String.t(), String.t(), [String.t()]) :: :inherited | :not_inherited | :unknown
  def inherited?(state, name, merge_base, commits) do
    order = commits |> Enum.reverse() |> Enum.with_index() |> Map.new()

    case Map.fetch(order, merge_base) do
      :error -> :unknown
      {:ok, base_index} -> inherited_check(state.history, name, order, base_index)
    end
  end

  defp expire(state, now) do
    history = Enum.reject(state.history, &(&1.completed_at < now - @retention_ms))
    signatures = Enum.reject(state.emitted_signatures, fn {_signature, at} -> at < now - @retention_ms end)
    %{state | history: history, emitted_signatures: signatures}
  end

  defp complete?(observation) do
    observation.checks != [] and is_integer(observation.completed_at) and
      Enum.all?(observation.checks, &(&1.conclusion in (@passing ++ @failing))) and
      (Map.get(observation, :failed_workflow, false) or Enum.all?(observation.checks, &(&1.conclusion != "cancelled")))
  end

  defp remember(state, observation) do
    entry = Map.take(observation, [:sha, :event, :started_at, :completed_at, :checks, :digest, :run_fingerprint, :failed_workflow, :run_urls, :suspect_merges])
    history = Enum.reject(state.history, &(&1.sha == entry.sha)) ++ [entry]
    %{state | history: history}
  end

  defp transition(state, observation) do
    if Enum.all?(observation.checks, &(&1.conclusion in @passing)), do: green(state, observation), else: red(state, observation)
  end

  defp green(state, observation) do
    payload = payload(state, observation)
    recovery = Map.merge(payload, %{red_since: state.red_since, recovered_at: observation.completed_at})
    events = if state.status == :red, do: [{"system.main.ci.failed.resolved", recovery}], else: []
    {%{state | status: :green, sha: observation.sha, last_green_sha: observation.sha, red_since: nil, completed_at: observation.completed_at, event: Map.get(observation, :event)}, events}
  end

  defp red(state, observation) do
    digest = observation.digest
    flaked = digest.flake_only and digest.tests != :unknown and not digest.truncated
    topic = if flaked, do: "system.main.ci.flaked", else: "system.main.ci.failed"
    signature = {topic, signature(digest, observation.checks, flaked)}
    emitted? = Enum.any?(state.emitted_signatures, fn {previous, _at} -> previous == signature end)
    events = if emitted?, do: [], else: [{topic, payload(state, observation)}]
    signatures = if emitted?, do: state.emitted_signatures, else: [{signature, observation.completed_at} | state.emitted_signatures]
    first_red_at = Map.get(observation, :started_at) || observation.completed_at
    since = if state.status == :red, do: state.red_since, else: first_red_at
    {%{state | status: :red, sha: observation.sha, red_since: since, completed_at: observation.completed_at, event: Map.get(observation, :event), emitted_signatures: signatures}, events}
  end

  defp signature(digest, checks, false) do
    digest.signature || {:unknown, checks |> Enum.filter(&(&1.conclusion in @failing)) |> Enum.map(& &1.name) |> Enum.sort()}
  end

  defp signature(digest, _checks, true), do: Enum.sort(Enum.map(digest.tests, & &1.identity))

  defp payload(state, observation) do
    %{
      sha: observation.sha,
      signature: observation.digest.signature,
      run_urls: Map.get(observation, :run_urls, []),
      failing_checks: Enum.filter(observation.checks, &(&1.conclusion in @failing)),
      failing_tests: observation.digest.tests,
      last_green_sha: state.last_green_sha,
      suspect_merges: Map.get(observation, :suspect_merges, [])
    }
  end

  defp inherited_check(history, name, order, base_index) do
    evidence =
      history
      |> Enum.flat_map(fn entry -> check_evidence(entry, name, order) end)
      |> Enum.sort_by(&elem(&1, 0))

    failures = Enum.filter(evidence, fn {index, conclusion} -> index <= base_index and conclusion in @failing end)
    verified = Enum.any?(failures, fn {failed_at, _} -> recovered_after_base?(evidence, failed_at, base_index) end)

    cond do
      verified -> :inherited
      evidence == [] -> :unknown
      true -> :not_inherited
    end
  end

  defp check_evidence(entry, name, order) do
    with {:ok, index} <- Map.fetch(order, entry.sha),
         %{conclusion: conclusion} <- Enum.find(entry.checks, &(&1.name == name)) do
      [{index, conclusion}]
    else
      _ -> []
    end
  end

  defp recovered_after_base?(evidence, failed_at, base_index) do
    case Enum.find(evidence, fn {index, conclusion} -> index > failed_at and conclusion in @passing end) do
      {index, _} -> index > base_index
      nil -> false
    end
  end
end
