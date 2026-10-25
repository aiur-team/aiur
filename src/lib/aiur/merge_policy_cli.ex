defmodule Aiur.MergePolicyCLI do
  @moduledoc "Merge policy visibility for the local control CLI."

  alias Aiur.Instance.RepositoryLeader

  @spec print() :: :ok
  def print, do: print(Aiur.LandingWatch)

  @doc false
  @spec print(GenServer.server()) :: :ok
  def print(landing_watch_server) do
    policy = Aiur.MergePolicy.current()
    role = Aiur.Config.booted_instance_role()
    state = if role == "primary" and Process.whereis(Aiur.MainWatch), do: Aiur.MainWatch.state(), else: %{watcher: :not_running}

    landing =
      cond do
        role != "primary" ->
          %{watcher: :not_running}

        landing_watch_server == Aiur.LandingWatch and not Process.whereis(Aiur.LandingWatch) ->
          %{watcher: :not_running}

        true ->
          Aiur.LandingWatch.state(landing_watch_server)
      end

    IO.puts(status_line(policy, role, state, landing))
    IO.puts(leader_status_line(RepositoryLeader.status()))
  end

  @spec leader_status_line(map()) :: String.t()
  def leader_status_line(leader),
    do: "REPOSITORY LEADER holder=#{leader.leader} lease_age=#{leader.lease_age}"

  defp status_line(policy, role, state, landing) do
    "MERGE POLICY ci=#{policy.ci} local_tests=#{policy.local_tests}#{labels(policy)} role=#{role} repo_global_off=#{disabled(role)} main_watch=#{watch(policy, role)} watcher=#{state.watcher}#{watch_error(state)} landing_watcher=#{landing.watcher}#{main(policy, state)}"
  end

  defp labels(%{ci: "wait", full_ci_labels: ["main-fix"]}), do: ""
  defp labels(policy), do: " full_ci=[#{Enum.join(policy.full_ci_labels, ",")}]"

  defp disabled("secondary"), do: "[landing_watch,quarantine_lifter,merge_queue_watchdog,main_watch]"
  defp disabled(_role), do: "none"

  defp watch(_policy, "secondary"), do: "off(secondary)"
  defp watch(%{main_watch: %{enabled: true, on_red: on_red}}, _role), do: "on(#{on_red})"
  defp watch(_policy, _role), do: "off"

  defp watch_error(%{last_error: error}) when is_binary(error), do: " watcher_error=#{error}"
  defp watch_error(_state), do: ""

  defp main(%{main_watch: %{enabled: true}}, state), do: " " <> main_state(state)

  defp main(_policy, %{watcher: watcher} = state) when watcher != :not_running, do: " " <> main_state(state)

  defp main(_policy, _state), do: ""

  @spec main_state(map(), integer()) :: String.t()
  def main_state(state, now_ms \\ System.system_time(:millisecond))

  def main_state(%{unavailable: true} = state, now_ms) do
    "main=unavailable last_known=" <>
      String.replace_prefix(main_state(Map.delete(state, :unavailable), now_ms), "main=", "") <>
      runner_starvation(state)
  end

  def main_state(%{status: :red} = state, now_ms) do
    since =
      case red_time(Map.get(state, :red_since)) do
        {:ok, time} -> " since " <> DateTime.to_iso8601(time)
        _ -> " since unknown"
      end

    fixer = if state[:fixer_ticket], do: " (##{state.fixer_ticket})", else: ""
    "main=red" <> observation(state, now_ms) <> since <> fixer
  end

  def main_state(%{status: :green} = state, now_ms), do: "main=green" <> event_source(state) <> observation(state, now_ms)
  def main_state(_state, _now_ms), do: "main=unknown"

  defp observation(state, now_ms) do
    age =
      case Map.get(state, :completed_at) do
        timestamp when is_integer(timestamp) -> "#{div(max(now_ms - timestamp, 0), 1_000)}s"
        _ -> "unknown"
      end

    " sha=#{Map.get(state, :sha) || "unknown"} age=#{age}"
  end

  defp runner_starvation(%{runner_starvation: %{queued_runs: queued, running_runs: running, status_url: url}}),
    do: " runner_starvation=#{queued}_queued_#{running}_running status=#{url}"

  defp runner_starvation(_state), do: ""

  defp event_source(%{event: event}) when is_binary(event), do: " (#{event})"
  defp event_source(_state), do: ""

  defp red_time(value) when is_integer(value), do: DateTime.from_unix(value, :millisecond)
  defp red_time(_value), do: {:error, :invalid_timestamp}
end
