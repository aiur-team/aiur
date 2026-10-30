defmodule Aiur.Executor.SessionCLI do
  @moduledoc false
  alias Aiur.Executor.{HarnessSession, Session}
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @spec rpc(keyword()) :: :ok
  def rpc(opts), do: guarded("executor-session", fn -> opts |> run() |> exit_marker() end)

  @spec run(keyword()) :: 0
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    binding =
      case Session.current() do
        :none -> %{state: "detached", live?: false}
        {:ok, binding} -> Session.public(binding)
      end

    counts = Session.rejected_counts()
    status = Map.merge(binding, age(binding, now))
    status = Map.merge(status, %{observed_at: DateTime.to_iso8601(now), foreign_session_count: Map.get(counts, :foreign_session, 0), not_attached_count: Map.get(counts, :not_attached, 0)})
    status = Map.put(status, :harness_session, HarnessSession.current(Keyword.take(opts, [:now, :path])))
    IO.puts(if Keyword.get(opts, :json, false), do: Jason.encode!(status), else: render(status))
    0
  end

  @spec age(map(), DateTime.t()) :: map()
  def age(binding, now) do
    case Map.get(binding, :last_hook_at) do
      nil ->
        %{age_ms: nil, freshness: "unknown"}

      at ->
        {:ok, at, _} = DateTime.from_iso8601(at)
        %{age_ms: max(DateTime.diff(now, at, :millisecond), 0), freshness: if(binding.live?, do: "fresh", else: "stale")}
    end
  end

  defp render(status) do
    "#{String.upcase(status.state)} binding=#{Map.get(status, :binding_id, "-")} harness=#{Map.get(status, :harness, "-")} live=#{status.live?}\n" <>
      "observed_at=#{status.observed_at} age_ms=#{status.age_ms || "unknown"} freshness=#{status.freshness}\n" <>
      "foreign_session=#{status.foreign_session_count} not_attached=#{status.not_attached_count}\n" <>
      "harness_session=#{Jason.encode!(status.harness_session)}"
  end
end
