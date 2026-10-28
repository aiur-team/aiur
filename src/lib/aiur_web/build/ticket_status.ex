defmodule AiurWeb.Build.TicketStatus do
  @moduledoc "Shared Build modal and deck ticket status labels. Unknown agent state remains nil."

  @states %{
    "active" => {"Running", "active"},
    "error" => {"Error", "stuck"},
    "retries" => {"Retries exhausted", "stuck"},
    "retrying" => {"Retrying", "queued"},
    "command" => {"Awaiting command", "stuck"},
    "paused" => {"Paused", "idle"},
    "parked" => {"Parked", "idle"},
    "merge-queued" => {"agent:merge-queued", "queued"},
    "ci-red" => {"agent:ci-red", "stuck"},
    "body-fix" => {"agent:body-fix", "stuck"},
    "paused-usage-limit" => {"agent:paused-usage-limit", "idle"},
    "paused-decision" => {"agent:paused-decision", "idle"},
    "paused-agent" => {"agent:paused-agent", "idle"},
    "blocked" => {"agent:blocked", "queued"},
    "handed-off" => {"agent:handed-off", "idle"},
    "usage_limited" => {"Paused · usage limit", "idle"},
    "ci_wait" => {"Waiting for CI", "idle"}
  }
  @history %{"done" => {"Merged", "done"}, "failed" => {"Failed", "stuck"}, "not_planned" => {"Not planned", "idle"}, "closed" => {"Closed", "idle"}}
  @unknown {"State unknown", "idle"}

  @spec encode(map() | nil) :: %{label: String.t(), tone: String.t(), agent_state: String.t() | nil}
  def encode(nil), do: %{label: "State unknown", tone: "idle", agent_state: nil}

  def encode(row) do
    state = if row[:sec] == "now", do: get_in(row, [:agent, :state])
    {label, tone} = presentation(row)
    %{label: label, tone: tone, agent_state: state}
  end

  defp presentation(%{sec: "now"} = row), do: Map.get(@states, get_in(row, [:agent, :state]), @unknown)
  defp presentation(%{sec: "hist"} = row), do: Map.get(@history, row[:status], @unknown)
  defp presentation(%{sec: "plan"} = row), do: {if(unfiled?(row), do: "Planned · not filed", else: "Queued · " <> queue(row[:qpos])), "idle"}
  defp presentation(%{sec: "nq"}), do: {"Not queued", "idle"}
  defp presentation(_row), do: @unknown

  defp unfiled?(%{num: nil, src: %{kind: "pack"}}), do: true
  defp unfiled?(%{num: nil, id: "pack:" <> _rest} = row), do: is_nil(row[:src])
  defp unfiled?(_row), do: false
  defp queue(nil), do: "Q?"
  defp queue(position) when is_number(position), do: "Q" <> to_string(position)
  defp queue(_position), do: "Q—"
end
