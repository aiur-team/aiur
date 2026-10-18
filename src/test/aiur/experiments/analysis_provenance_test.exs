defmodule Aiur.Experiments.AnalysisProvenanceTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{AnalysisProvenance, AnalysisTicket}
  alias Aiur.Issue

  defp request do
    %{
      "request_id" => "req-" <> String.duplicate("a", 32),
      "nonce" => String.duplicate("b", 32),
      "state" => "open",
      "daemon_login" => "daemon[bot]",
      "ticket" => %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}
    }
  end

  defp issue(request) do
    %Issue{id: "42", url: request["ticket"]["url"], creator_login: "Daemon[bot]", labels: ["experiment-analysis"], description: AnalysisTicket.marker(request)}
  end

  test "only the open request's attached daemon-authored ticket and exact nonce authorize" do
    request = request()
    issue = issue(request)
    assert AnalysisProvenance.authorized?(issue, request)

    for invalid <- [
          %{issue | description: String.replace(issue.description, "nonce=b", "nonce=c")},
          %{issue | creator_login: "outsider"},
          %{issue | id: "43"},
          %{issue | url: "https://github.com/other/repo/issues/42"},
          %{issue | labels: []},
          %{issue | description: nil},
          %{issue | description: issue.description <> issue.description}
        ] do
      refute AnalysisProvenance.authorized?(invalid, request)
    end

    for state <- ["fulfilled", "cancelled", "failed"] do
      refute AnalysisProvenance.authorized?(issue, Map.put(request, "state", state))
    end

    refute AnalysisProvenance.authorized?(issue, Map.put(request, "daemon_login", "other-daemon[bot]"))
    refute AnalysisProvenance.authorized?(issue, Map.delete(request, "daemon_login"))
    refute AnalysisProvenance.authorized?(issue, Map.put(request, "ticket", nil))
  end
end
