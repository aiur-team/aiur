defmodule Aiur.MergePolicyCLI do
  @moduledoc "Merge policy visibility for the local control CLI."

  @spec print() :: :ok
  def print do
    policy = Aiur.MergePolicy.current()
    watch = if policy.main_watch.enabled, do: "on(#{policy.main_watch.on_red})", else: "off"
    labels = if policy.ci == "wait" and policy.full_ci_labels == ["main-fix"], do: "", else: " full_ci=[#{Enum.join(policy.full_ci_labels, ",")}]"
    state = Aiur.MainWatch.state()
    landing = Aiur.LandingWatch.state()
    main = if policy.main_watch.enabled or state.watcher != :not_running, do: " " <> main_state(state), else: ""
    IO.puts("MERGE POLICY ci=#{policy.ci} local_tests=#{policy.local_tests}#{labels} main_watch=#{watch} watcher=#{state.watcher} landing_watcher=#{landing.watcher}#{main}")
  end

  @spec main_state(map(), integer()) :: String.t()
  def main_state(state, now_ms \\ System.system_time(:millisecond))

  def main_state(%{unavailable: true} = state, now_ms) do
    "main=unavailable last_known=" <> String.replace_prefix(main_state(Map.delete(state, :unavailable), now_ms), "main=", "")
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

  def main_state(%{status: :green} = state, now_ms), do: "main=green" <> observation(state, now_ms)
  def main_state(_state, _now_ms), do: "main=unknown"

  defp observation(state, now_ms) do
    age =
      case Map.get(state, :completed_at) do
        timestamp when is_integer(timestamp) -> "#{div(max(now_ms - timestamp, 0), 1_000)}s"
        _ -> "unknown"
      end

    " sha=#{Map.get(state, :sha) || "unknown"} age=#{age}"
  end

  defp red_time(value) when is_integer(value), do: DateTime.from_unix(value, :millisecond)
  defp red_time(_value), do: {:error, :invalid_timestamp}
end
