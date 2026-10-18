defmodule Aiur.Orchestrator.ToolchainPreflightTest do
  use Aiur.TestSupport

  alias Aiur.AlertFeed
  alias Aiur.Orchestrator.{Dispatcher, State, ToolchainPreflight}

  @missing ~s([{"version":"28.5","requested_version":"28.5","install_path":"/home/u/.local/share/mise/installs/erlang/28.5","installed":false}])
  @present ~s([{"version":"28.5","requested_version":"28.5","install_path":"/home/u/.local/share/mise/installs/erlang/28.5","installed":true}])

  setup do
    previous_opts = Application.fetch_env!(:aiur, :toolchain_preflight_opts)
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "toolchain-preflight-token")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

    on_exit(fn ->
      Application.put_env(:aiur, :toolchain_preflight_opts, previous_opts)
      restore_env("GITHUB_TOKEN", previous_token)
    end)

    :ok
  end

  defp mise_reporting(output, status \\ 0) do
    [mise: "/usr/bin/mise", dir: "/repo", runner: fn "/usr/bin/mise", ["ls", "--current", "--json", "erlang"], [cd: "/repo"] -> {output, status} end]
  end

  defp attentions, do: Enum.filter(AlertFeed.list(needs_attention: true), &(&1["topic"] == ToolchainPreflight.alert_name()))

  test "a missing Erlang install holds dispatch and raises one attention" do
    Application.put_env(:aiur, :toolchain_preflight_opts, mise_reporting(@missing))
    owner = self()
    dispatch = fn state -> send(owner, :dispatch_attempted) && state end

    held = Dispatcher.maybe_dispatch(%State{}, dispatch)
    held = Dispatcher.maybe_dispatch(held, dispatch)

    refute_received :dispatch_attempted
    assert %{reason: :tracker_preflight, detail: :toolchain_missing} = held.dispatch_hold
    assert [alert] = attentions()
    assert alert["reason"] =~ "erlang 28.5 (requested 28.5) is missing"
  end

  test "a restored install resolves the attention" do
    assert {:error, {:toolchain_missing, _detail}} = ToolchainPreflight.check(mise_reporting(@missing))
    assert [_alert] = attentions()

    assert :ok = ToolchainPreflight.check(mise_reporting(@present))
    assert [] = attentions()
  end

  test "hosts without mise, repos without Erlang, and failing mise calls pass" do
    assert :ok = ToolchainPreflight.check(mise: nil)
    assert :ok = ToolchainPreflight.check(mise_reporting("[]"))
    assert :ok = ToolchainPreflight.check(mise_reporting("mise ERROR config not trusted", 1))
    assert [] = attentions()
  end
end
