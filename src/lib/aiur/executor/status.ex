defmodule Aiur.Executor.Status do
  @moduledoc "A bounded, read-only snapshot of the Executor and its wake stream."

  alias Aiur.Executor.{BackgroundAgents, Blockers, Capability, HarnessSession, HarnessState, Roster, Session, SessionIngest, TranscriptIngest}
  alias Aiur.ExecutorWakeInbox

  @part_timeout_ms 1_000

  @spec snapshot() :: map()
  def snapshot, do: snapshot([])

  @doc false
  @spec snapshot(keyword()) :: map()
  def snapshot(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    claim_opts = Keyword.put(Keyword.take(opts, [:path]), :now, now)
    parts = read_parts(now, claim_opts)

    parts
    |> Map.drop([:transcript, :rejections])
    |> Map.merge(transcript_fields(parts.transcript))
    |> Map.merge(rejection_fields(parts.rejections))
    |> Map.merge(%{attached: attached(parts.binding), read_capability: read_capability(parts, now), observed_at: now})
  end

  defp read_parts(now, claim_opts) do
    deadline = System.monotonic_time(:millisecond) + @part_timeout_ms
    wake_task = start_part(&wakes/0)

    tasks =
      [
        binding: fn -> read_binding(now) end,
        harness_state: &HarnessState.snapshot/0,
        background_agents: &background_agents/0,
        blockers: fn -> Blockers.snapshot(now: now, timeout: 750) end,
        transcript: &TranscriptIngest.status/0,
        rejections: &SessionIngest.rejected_counts/0,
        harness_session: fn -> HarnessSession.current(claim_opts) end
      ]
      |> Enum.map(fn {key, read} -> {key, start_part(read)} end)

    wakes = value(wake_task, Task.yield(wake_task, remaining(deadline)))
    tasks = [roster: start_part(fn -> roster(claim_opts, wakes) end)] ++ tasks
    Map.put(await_parts(tasks, deadline), :wakes, wakes)
  end

  defp start_part(read), do: Aiur.Project.Task.async(fn -> safely(read) end)
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp await_parts(tasks, deadline) do
    results = tasks |> Keyword.values() |> Task.yield_many(remaining(deadline))

    tasks
    |> Keyword.keys()
    |> Enum.zip(results)
    |> Map.new(fn {key, {task, result}} -> {key, value(task, result)} end)
  end

  defp safely(read) do
    read.()
  catch
    _kind, _reason -> :unavailable
  end

  defp value(task, nil), do: value(task, Task.shutdown(task, :brutal_kill) || {:exit, :timeout})
  defp value(_task, {:ok, result}), do: result
  defp value(_task, _), do: :unavailable

  defp read_binding(now) do
    case Session.current() do
      {:ok, binding} -> binding |> Session.public() |> Map.merge(binding_age(binding, now))
      :none -> nil
    end
  end

  @doc false
  @spec binding_age(map(), DateTime.t()) :: map()
  def binding_age(%{last_hook_at: at, live?: live?}, now) when is_binary(at) do
    {:ok, at, _offset} = DateTime.from_iso8601(at)
    %{age_ms: max(DateTime.diff(now, at, :millisecond), 0), freshness: if(live?, do: "fresh", else: "stale")}
  end

  def binding_age(_binding, _now), do: %{age_ms: nil, freshness: "unknown"}

  defp attached(:unavailable), do: :unavailable
  defp attached(nil), do: false
  defp attached(binding), do: binding.state != "detached"

  defp background_agents do
    case BackgroundAgents.snapshot() do
      {:ok, rows, _observed_since} -> {:ok, rows}
      unsupported -> unsupported
    end
  end

  defp wakes do
    case ExecutorWakeInbox.stats() do
      {:ok, stats} -> stats
      {:error, _reason} -> :unavailable
    end
  end

  defp roster(opts, %{cursor: cursor, pending_count: pending_count}) do
    opts |> Keyword.merge(cursor: cursor, pending_count: pending_count, record?: false) |> Roster.build() |> Map.fetch!(:executors)
  end

  defp roster(_opts, :unavailable), do: :unavailable

  defp read_capability(%{binding: :unavailable}, _now), do: :unavailable

  defp read_capability(%{binding: binding, transcript: transcript}, now) do
    safely(fn ->
      format = Map.get(binding || %{}, :transcript_format) || %{}
      Capability.read(binding, Map.merge(format, transcript_fields(transcript)), now)
    end)
  end

  defp transcript_fields(:unavailable), do: %{transcript_rejection: :unknown}
  defp transcript_fields(fields), do: fields

  defp rejection_fields(:unavailable), do: %{recording?: false, foreign_session_count: nil, not_attached_count: nil}
  defp rejection_fields(counts), do: %{recording?: true, foreign_session_count: Map.get(counts, :foreign_session, 0), not_attached_count: Map.get(counts, :not_attached, 0)}
end
