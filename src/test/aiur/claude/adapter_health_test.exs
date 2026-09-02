defmodule Aiur.Claude.AdapterHealthTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, Issue}
  alias Aiur.Claude.AdapterHealth

  describe "release_status/1" do
    test "recognizes the exact published npm version with bounded requests" do
      parent = self()

      request = fn url, opts ->
        send(parent, {:request, url, opts})
        {:ok, %{status: 200, body: %{"version" => "1.1.0"}}}
      end

      assert AdapterHealth.release_status(request) == :available

      assert_received {:request, "https://registry.npmjs.org/aiur-claude/1.1.0", opts}
      assert opts[:retry] == false
      assert opts[:receive_timeout] == 5_000
      assert opts[:connect_options][:timeout] == 5_000
    end

    test "distinguishes a confirmed 404 from registry uncertainty" do
      assert AdapterHealth.release_status(fn _url, _opts -> {:ok, %{status: 404, body: %{}}} end) == :not_found

      assert {:unknown, {:unexpected_status, 503}} =
               AdapterHealth.release_status(fn _url, _opts -> {:ok, %{status: 503, body: %{}}} end)

      assert {:unknown, :timeout} = AdapterHealth.release_status(fn _url, _opts -> {:error, :timeout} end)

      assert {:unknown, :unexpected_metadata} =
               AdapterHealth.release_status(fn _url, _opts -> {:ok, %{status: 200, body: %{"version" => "1.0.0"}}} end)
    end
  end

  describe "install source and remediation" do
    test "uses exact npm only after confirmed availability" do
      assert AdapterHealth.install_spec(:available) == "aiur-claude@1.1.0"

      assert AdapterHealth.install_spec(:not_found) ==
               "github:aiur-team/aiur-claude#3478281243bfec8b9e1719461ff17c836c07c5b8"

      assert AdapterHealth.install_spec({:unknown, :timeout}) ==
               "github:aiur-team/aiur-claude#3478281243bfec8b9e1719461ff17c836c07c5b8"
    end

    test "confirmed absence leads with the working uninstall and GitHub commands" do
      remediation = AdapterHealth.remediation(:not_found)

      assert remediation =~ "npm release is pending"
      assert remediation =~ "npm uninstall -g aiur-claude"
      assert remediation =~ "npm install -g github:aiur-team/aiur-claude#3478281243bfec8b9e1719461ff17c836c07c5b8"
      refute remediation =~ "npm install -g aiur-claude@1.1.0"
    end

    test "unknown availability is honest and offers both exact sources" do
      remediation = AdapterHealth.remediation({:unknown, :timeout})

      assert remediation =~ "couldn't confirm the npm release"
      assert remediation =~ "github:aiur-team/aiur-claude#3478281243bfec8b9e1719461ff17c836c07c5b8"
      assert remediation =~ "npm install -g aiur-claude@1.1.0"
      refute remediation =~ "npm release is pending"
    end
  end

  describe "version_status/1" do
    test "classifies capable, degraded, and unknown versions" do
      assert AdapterHealth.version_status({:ok, "1.1.0"}) == :capable
      assert AdapterHealth.version_status({:ok, "2.0.0"}) == :capable
      assert AdapterHealth.version_status({:ok, "1.0.0"}) == {:degraded, "1.0.0"}
      assert AdapterHealth.version_status({:ok, "nightly"}) == :unknown
      assert AdapterHealth.version_status({:error, "secret-bearing failure"}) == :unknown
    end
  end

  describe "installed_version/0" do
    test "treats a custom command as unknown instead of reading the wrapper version" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", command: "npx aiur-claude")

      assert AdapterHealth.installed_version() == {:error, :custom_or_unavailable_command}
    end

    test "bounds a stuck version probe and leaves runtime health unknown" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", command: "aiur-claude")
      parent = self()

      version_fun = fn ->
        AdapterHealth.installed_version(
          find_executable_fun: fn "aiur-claude" -> "/fake/aiur-claude" end,
          command_fun: fn _path, ["--version"], _opts ->
            send(parent, {:probe_started, self()})
            receive do: (:never -> :ok)
          end,
          timeout: 25
        )
      end

      health_task =
        Task.async(fn ->
          AdapterHealth.report_runtime(%Issue{id: "issue-timeout", identifier: "TIMEOUT"}, "/ws",
            version_fun: version_fun,
            condition_state_fun: fn _topic -> send(parent, :condition_read) end,
            emit_fun: fn _topic, _opts -> send(parent, :emitted) end
          )
        end)

      case Task.yield(health_task, 500) do
        {:ok, :ok} ->
          :ok

        nil ->
          Task.shutdown(health_task, :brutal_kill)
          flunk("runtime health did not return after the probe deadline")
      end

      assert_received {:probe_started, probe_pid}
      refute Process.alive?(probe_pid)
      refute_received :condition_read
      refute_received :emitted
    end
  end

  describe "report_runtime/4" do
    test "persists and resolves the real durable alert condition" do
      issue = %Issue{id: "issue-durable", identifier: "DURABLE"}
      condition = "ticket.DURABLE.agent.attention.adapter_degraded"

      assert :ok =
               AdapterHealth.report_runtime(issue, nil,
                 version_fun: fn -> {:ok, "1.0.0"} end,
                 release_status_fun: fn -> :not_found end
               )

      assert AlertFeed.condition_state(condition) == :firing

      assert :ok =
               AdapterHealth.report_runtime(issue, nil, version_fun: fn -> {:ok, "1.1.0"} end)

      assert AlertFeed.condition_state(condition) == :resolved
    end

    test "emits one normalized degradation condition and suppresses duplicates" do
      issue = %Issue{id: "issue-degraded", identifier: "DEGRADED"}
      parent = self()

      emit = fn topic, opts ->
        send(parent, {:emit, topic, opts})
        :ok
      end

      deps = [
        version_fun: fn -> {:ok, "1.0.0"} end,
        release_status_fun: fn -> :not_found end,
        condition_state_fun: fn _topic -> :unknown end,
        emit_fun: emit
      ]

      assert :ok = AdapterHealth.report_runtime(issue, "/ws", deps)

      assert_received {:emit, "ticket.DEGRADED.agent.attention.adapter_degraded", opts}
      assert opts[:needs_attention]
      assert opts[:severity] == "warning"
      assert opts[:reason] =~ "aiur-claude 1.0.0"
      assert opts[:reason] =~ "aiur_declare_blocker"
      refute inspect(opts) =~ "secret"

      assert :ok =
               AdapterHealth.report_runtime(issue, "/ws", Keyword.put(deps, :condition_state_fun, fn _topic -> :firing end))

      refute_received {:emit, _, _}
    end

    test "a capable adapter resolves an active degradation condition" do
      issue = %Issue{id: "issue-capable", identifier: "CAPABLE"}
      parent = self()

      assert :ok =
               AdapterHealth.report_runtime(issue, "/ws",
                 version_fun: fn -> {:ok, "1.1.0"} end,
                 condition_state_fun: fn _topic -> :firing end,
                 emit_fun: fn topic, opts ->
                   send(parent, {:emit, topic, opts})
                   :ok
                 end
               )

      assert_received {:emit, "ticket.CAPABLE.agent.attention.adapter_degraded.resolved", opts}
      refute opts[:needs_attention]
    end

    test "unknown state leaves the durable condition unchanged without leaking diagnostics" do
      issue = %Issue{id: "issue-unknown", identifier: "UNKNOWN"}
      parent = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   AdapterHealth.report_runtime(issue, "/ws",
                     version_fun: fn -> {:error, "token=super-secret /private/path"} end,
                     condition_state_fun: fn _topic -> send(parent, :condition_read) end,
                     emit_fun: fn _topic, _opts -> send(parent, :emitted) end
                   )
        end)

      refute_received :condition_read
      refute_received :emitted
      refute log =~ "super-secret"
      refute log =~ "/private/path"
      assert log =~ "could not determine aiur-claude adapter health"
    end
  end
end
