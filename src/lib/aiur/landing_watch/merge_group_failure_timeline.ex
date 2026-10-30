defmodule Aiur.LandingWatch.MergeGroupFailureTimeline do
  @moduledoc false

  alias Aiur.Events
  alias Aiur.LandingWatch.MergeGroupFailureEvidence

  @spec publish(pos_integer(), [map()], map(), map(), keyword()) :: term()
  def publish(number, observations, failure, run, opts) do
    identity_fun = Keyword.get(opts, :ticket_identity_fun, &Aiur.Orchestrator.tracker_identity/1)

    with %{rest: rest} when is_map(rest) <- Enum.find(observations, &(&1.number == number)),
         ticket when is_binary(ticket) <- Aiur.TicketBranch.ticket_id(get_in(rest, ["head", "ref"])),
         identity when not is_nil(identity) <- identity_fun.(ticket) do
      checks = Enum.map(failure_identities(failure), &%{name: &1, url: safe_run_url(run["html_url"])})
      message = "Merge-group run #{run["id"]} failed twice for PR ##{number}; PR was removed from the merge queue."

      Events.publish("ticket.#{ticket}.ci.merge_group.failed", %{message: message, checks: checks, pr_number: number, run_id: run["id"]},
        issue_number: ticket,
        identity: identity,
        bypass_contamination: true
      )
    else
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp failure_identities(%{log: log, job: job}) do
    case MergeGroupFailureEvidence.test_identities(log) do
      [_ | _] = identities -> Enum.sort(identities)
      [] -> [job["name"] || "unknown failing spec"]
    end
  end

  defp failure_identities(_), do: ["unknown failing spec"]

  defp safe_run_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and uri.host == "github.com" and is_nil(uri.userinfo) and
         String.starts_with?(uri.path || "", "/") and String.contains?(uri.path || "", "/actions/runs/") do
      URI.to_string(%{uri | query: nil, fragment: nil})
    end
  rescue
    _ -> nil
  end

  defp safe_run_url(_), do: nil
end
