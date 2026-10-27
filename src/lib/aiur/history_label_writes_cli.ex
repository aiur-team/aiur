defmodule Aiur.HistoryLabelWritesCLI do
  @moduledoc "Control RPC for optional paced history label writes."
  alias Aiur.BuildOrder.History.LabelBackfill
  alias Aiur.ControlCLI.Protocol
  alias Aiur.JSONSafe

  @spec rpc(keyword()) :: :ok
  def rpc(opts), do: Protocol.guarded("history label-writes", fn -> opts |> run() |> Protocol.exit_marker() end)

  @spec run(keyword()) :: 0 | 1
  def run(opts) do
    action = Keyword.get(opts, :action, :status)

    case execute(action, Keyword.delete(opts, :action)) do
      {:error, reason} ->
        Protocol.control_error("aiur: history label-writes: #{inspect(reason)}")
        1

      result ->
        output = JSONSafe.normalize(result)
        IO.puts(if opts[:json], do: Jason.encode!(output), else: render(output))
        0
    end
  end

  defp execute(:plan, opts), do: LabelBackfill.plan(opts)
  defp execute(:start, opts), do: LabelBackfill.start(opts)
  defp execute(:pause, opts), do: LabelBackfill.pause(opts)
  defp execute(:resume, opts), do: LabelBackfill.resume(opts)
  defp execute(:status, opts), do: LabelBackfill.status(opts)
  defp execute(_, _), do: {:error, :invalid_action}

  @spec render(map()) :: String.t()
  def render(%{"total" => total} = plan) do
    "history label-writes plan: #{total} requests (feature #{plan["writes"]["feature"]}, epic #{plan["writes"]["epic"]}, ensure #{plan["ensure"]}); #{plan["hours"]} hours\n" <>
      "tracker: #{plan["tracker"]}; skipped: #{Jason.encode!(plan["skipped"])}; deferred: #{Jason.encode!(plan["deferred"])}; unknown: #{Enum.join(plan["unknown"], ", ")}\n#{plan["cost"]}"
  end

  def render(%{"run" => run} = status) do
    "history label-writes: #{run["state"]}; ceiling #{run["per_hour"]}/h; requests last hour #{status["requests_last_hour"]}\n" <>
      "items: #{Jason.encode!(status["counts"])}; writes #{status["writes"]}; stop reason #{run["stop_reason"] || "none"}\n" <>
      "hold until #{run["hold_until"] || "none"} (#{status["hold_remaining_ms"]}ms remaining)\n" <>
      "last write #{timestamp(status["last_write"])}; history #{timestamp(status["history"])}"
  end

  defp timestamp(%{"observed_at" => at, "age_ms" => ms}) when is_integer(ms), do: "#{at} (#{div(ms, 60_000)}m ago)"
  defp timestamp(_), do: "unknown"
end
