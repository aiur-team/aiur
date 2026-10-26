defmodule Aiur.GitHub.HoldPressureWiringTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.GitHub.{HoldPressure, Transport}

  # The supervised monitor is shared with every other test, so these assert on
  # the rarely-used "search" resource and on growth, never on an absolute count.
  defmodule HeldQuota do
    use GenServer

    def start_link(hold), do: GenServer.start_link(__MODULE__, hold)
    def init(hold), do: {:ok, hold}
    def handle_call({:preflight, _request}, _from, hold), do: {:reply, {:hold, hold}, hold}
  end

  test "a request the local guard holds is counted against its resource" do
    hold = %{reason: :shared_budget, resource: "search", reset_at: DateTime.utc_now()}
    previous = Application.get_env(:aiur, :github_quota_server)
    Application.put_env(:aiur, :github_quota_server, start_supervised!({HeldQuota, hold}))
    on_exit(fn -> if previous, do: Application.put_env(:aiur, :github_quota_server, previous), else: Application.delete_env(:aiur, :github_quota_server) end)

    before = Map.get(HoldPressure.per_minute(), "search", 0)
    url = "https://api.github.com/search/issues?q=hold-pressure-#{System.unique_integer([:positive])}"

    assert {:error, {:aiur, :locally_held, ^hold}} = Transport.default_request_fun(%{method: :get, url: url, token: "test-gh-token"})
    assert Map.get(HoldPressure.per_minute(), "search", 0) == before + 1
  end

  test "status prints the hold rate on a GitHub tracker" do
    path = Aiur.Workflow.workflow_file_path()
    original = File.read!(path)
    on_exit(fn -> File.write!(path, original) end)
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo")
    HoldPressure.record(%{resource: "search"})

    assert capture_io(fn -> AgentControlCLI.status() end) =~ ~r{GITHUB HOLDS core=\d+/min graphql=\d+/min search=[1-9]\d*/min}
  end
end
