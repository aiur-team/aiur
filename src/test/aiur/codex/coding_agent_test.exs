defmodule Aiur.Codex.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Adapter
  alias Aiur.AppServer.Rpc, as: AppServerRpc
  alias Aiur.Codex.{AccountGeneration, AppServerPort, CodingAgent, Frames, Handshake}
  alias Aiur.Codex.Rpc, as: CodexRpc
  alias Aiur.ProviderAccountGeneration

  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()
  @stderr_probe_skip_reason @pgrep_skip_reason ||
                              if(File.exists?("/proc/self/fd/2"), do: false, else: "requires Linux /proc fd ownership")
  @stderr_child_marker "aiur-stderr-lifecycle-child"

  describe "stop_session/1 reaps the app-server process tree" do
    @tag skip: @pgrep_skip_reason
    # The codex backend launches `bash -lc "codex ... app-server"`. bash forks
    # a `node` -> rust `codex` grandchild it does NOT exec into. Closing only
    # the port kills the bash wrapper and leaves that grandchild reparented to
    # init — a live app-server still holding the global ~/.codex/state_5.sqlite
    # lock, which poisons every subsequent codex agent with "database is locked".
    # Teardown must reap the whole tree.
    test "kills the bash wrapper AND its surviving child" do
      command = "sleep 600 & printf 'up\\n'; wait"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      {:os_pid, bash_pid} = :erlang.port_info(port, :os_pid)
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      child_pid = wait_for_child(bash_pid, 2_000)

      on_exit(fn ->
        for p <- [bash_pid, child_pid], is_integer(p) do
          System.cmd("kill", ["-KILL", Integer.to_string(p)], stderr_to_stdout: true)
        end
      end)

      assert is_integer(child_pid)
      assert os_alive?(child_pid)

      assert :ok = CodingAgent.stop_session(%{port: port})

      refute os_alive?(bash_pid)
      refute os_alive?(child_pid)
    end

    test "still closes the app-server port when the account-generation owner is unavailable" do
      {:ok, owner} = ProviderAccountGeneration.start_link(name: nil)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("cat"))},
          [:binary, :exit_status]
        )

      GenServer.stop(owner)

      assert :ok =
               CodingAgent.stop_session(%{
                 port: port,
                 account_generation_server: owner,
                 account_generation_binding: make_ref()
               })

      assert :undefined = :erlang.port_info(port)
    end

    @tag skip: @stderr_probe_skip_reason
    @tag :tmp_dir
    test "reaps a reparented same-group child before closing its stderr pipe", %{tmp_dir: tmp_dir} do
      probe_path = Path.join(tmp_dir, "probe.log")
      pid_path = Path.join(tmp_dir, "child.pid")

      on_exit(fn ->
        with {:ok, pid_string} <- File.read(pid_path),
             {pid, ""} <- pid_string |> String.trim() |> Integer.parse(),
             {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
             true <- String.contains?(cmdline, @stderr_child_marker) do
          System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end
      end)

      expression = """
      _marker = "#{@stderr_child_marker}"
      probe_path = System.fetch_env!("AIUR_STDERR_PROBE")
      standard_error = Process.whereis(:standard_error)

      File.write!(
        probe_path,
        inspect(%{
          group_leader: Process.group_leader(),
          standard_error: standard_error,
          fd2: File.read_link!("/proc/\#{System.pid()}/fd/2")
        }) <> "\\n"
      )

      Process.sleep(10_000)
      """

      elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")

      command =
        "AIUR_STDERR_PROBE=#{Aiur.Shell.escape(probe_path)} " <>
          "#{Aiur.Shell.escape(elixir)} -e #{Aiur.Shell.escape(expression)} & " <>
          "echo $! > #{Aiur.Shell.escape(pid_path)}; exit 0"

      assert {:ok, port} = Adapter.start_port(File.cwd!(), command)
      metadata = AppServerPort.port_metadata(port)

      assert {:ok, {probe, child_pid}} = eventually_read_probe(probe_path, pid_path)
      root_pid = metadata.codex_app_server_pid |> String.to_integer()
      process_group_id = metadata.agent_process_group_id |> String.to_integer()

      assert eventually(fn -> not os_alive?(root_pid) and os_alive?(child_pid) end)
      assert process_group(child_pid) == process_group_id
      assert probe =~ "standard_error: #PID"
      assert probe =~ "pipe:["

      assert :ok = CodingAgent.stop_session(%{port: port, metadata: metadata})
      refute os_alive?(child_pid)
    end
  end

  describe "thread-init frame (start vs resume)" do
    @policies %{approval_policy: "never", thread_sandbox: "read-only"}

    test "builds a thread/start frame with dynamicTools when not resuming" do
      frame = Frames.thread_init_frame(nil, "/ws", @policies)

      assert frame["method"] == "thread/start"
      assert frame["id"] == 2
      assert frame["params"]["cwd"] == "/ws"
      assert frame["params"]["approvalPolicy"] == "never"
      assert frame["params"]["sandbox"] == "read-only"
      # A fresh thread registers aiur's custom dynamic tools.
      assert is_list(frame["params"]["dynamicTools"])
    end

    test "builds a thread/resume frame carrying the threadId when resuming" do
      frame = Frames.thread_init_frame("thr_123", "/ws", @policies)

      assert frame["method"] == "thread/resume"
      assert frame["id"] == 2
      assert frame["params"]["threadId"] == "thr_123"
      assert frame["params"]["cwd"] == "/ws"
      assert frame["params"]["approvalPolicy"] == "never"
      assert frame["params"]["sandbox"] == "read-only"
      # The codex app-server's thread/resume has no dynamicTools param; the
      # registration is restored from the persisted rollout, so we must not
      # send one (it would be rejected as an unknown field).
      refute Map.has_key?(frame["params"], "dynamicTools")
    end
  end

  describe "resume_outcome/2 (resumed vs fresh vs clean-start fallback)" do
    test "a returned thread_id matching the requested one is a genuine resume" do
      assert Handshake.resume_outcome({:ok, "thr_1"}, "thr_1") == {:resumed, "thr_1"}
    end

    test "a DIFFERENT returned thread_id is treated as fresh, not a resume" do
      # Guards against codex silently substituting a new/empty thread: reporting
      # resumed?=true there would hand the agent a context-free continuation
      # prompt against a thread it never actually rejoined.
      assert Handshake.resume_outcome({:ok, "thr_other"}, "thr_1") == {:fresh, "thr_other"}
    end

    test "a resume error degrades to a clean-start fallback carrying the reason" do
      assert Handshake.resume_outcome({:error, {:response_error, %{}}}, "thr_1") ==
               {:fallback, {:response_error, %{}}}

      assert Handshake.resume_outcome({:error, :response_timeout}, "thr_1") ==
               {:fallback, :response_timeout}
    end
  end

  describe "parse_thread_response/1" do
    test "extracts the thread id from a well-formed start/resume response" do
      assert Handshake.parse_thread_response({:ok, %{"thread" => %{"id" => "thr_x"}}}) ==
               {:ok, "thr_x"}
    end

    test "a thread payload without an id is an invalid-thread-payload error" do
      assert {:error, {:invalid_thread_payload, %{"name" => "x"}}} =
               Handshake.parse_thread_response({:ok, %{"thread" => %{"name" => "x"}}})
    end

    test "an underlying error response passes through unchanged" do
      assert Handshake.parse_thread_response({:error, :response_timeout}) ==
               {:error, :response_timeout}
    end
  end

  describe "startup response timeout" do
    test "uses a cold-start floor without shortening explicit longer read timeouts" do
      assert CodexRpc.startup_response_timeout_ms(5_000) == 30_000
      assert CodexRpc.startup_response_timeout_ms(60_000) == 60_000
    end

    test "waits past the steady read timeout for startup responses" do
      command = "sleep 0.1; printf '%s\\n' '{\"id\":42,\"result\":{\"ok\":true}}'"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      timeout = CodexRpc.startup_response_timeout_ms(50)
      result = apply(AppServerRpc, String.to_atom("with_timeout_" <> "response"), [port, 42, timeout, "", "Codex"])
      assert {:ok, %{"ok" => true}} = result
      assert_receive {^port, {:exit_status, 0}}, 1_000
    end
  end

  describe "pre-turn lifecycle notifications" do
    test "uses run_turn's current message handler for a rate-limit notification" do
      secret = "person@example.test credential=super-secret"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              ~c"-lc",
              String.to_charlist("""
              while IFS= read -r line; do
                case "$line" in
                  *'"id":3'*)
                    printf '%s\\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"limited":false,"email":"#{secret}"}}}'
                    printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
                    printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
                    exit 0 ;;
                esac
              done
              """)
            ],
            line: 64_000
          ]
        )

      {:ok, owner} = ProviderAccountGeneration.start_link(name: nil)
      account_generation = AccountGeneration.new_binding(owner)
      test_pid = self()

      session = %{
        port: port,
        metadata: %{},
        auto_approve_requests: false,
        thread_id: "thread-1",
        workspace: "/ws",
        approval_policy: "never",
        turn_sandbox_policy: %{},
        account_generation_binding: account_generation.binding,
        account_generation_authority: account_generation.authority,
        account_generation_context: account_generation.context,
        account_generation_server: owner
      }

      assert {:redacted, _} =
               AccountGeneration.handle_notification(session, "account/updated", %{"params" => %{"authMode" => "chatgpt"}})

      assert {:ok, %{result: :turn_completed}} =
               CodingAgent.run_turn(
                 session,
                 "prompt",
                 %{id: "gid-pre-turn", identifier: "DASH-018", title: "test"},
                 on_message: fn message -> send(test_pid, {:turn_message, message}) end
               )

      assert_receive {:turn_message,
                      notification = %{
                        event: :notification,
                        payload: %{"method" => "provider_account/rate_limits_changed"},
                        rate_limits: %{"limited" => false}
                      }},
                     2_000

      refute inspect(notification) =~ secret
    end
  end

  describe "send_thread_init/2 graceful degradation" do
    test "a closed app-server port yields {:error, :port_closed} instead of raising" do
      # A dead app-server makes Port.command raise ArgumentError; the resume path
      # must see an error tuple so it can fall back to a clean start rather than
      # crashing the dispatch (issue #378: degrade gracefully).
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("cat"))},
          [:binary, :exit_status]
        )

      true = Port.close(port)

      frame =
        Frames.thread_init_frame("thr_1", "/ws", %{
          approval_policy: "never",
          thread_sandbox: "read-only"
        })

      assert {:error, :port_closed} = Handshake.send_thread_init(port, frame)
    end
  end

  defp wait_for_child(parent, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_for_child(parent, deadline)
  end

  defp do_wait_for_child(parent, deadline) do
    first_child =
      case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1) |> List.first()
        _ -> nil
      end

    cond do
      is_integer(first_child) ->
        first_child

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(25)
        do_wait_for_child(parent, deadline)
    end
  end

  defp os_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))

  defp process_group(pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _ -> nil
    end
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      true
    else
      Process.sleep(25)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: false

  defp eventually_read_probe(probe_path, pid_path, attempts \\ 100)

  defp eventually_read_probe(probe_path, pid_path, attempts) when attempts > 0 do
    with {:ok, probe} <- File.read(probe_path),
         {:ok, pid_string} <- File.read(pid_path),
         {pid, ""} <- pid_string |> String.trim() |> Integer.parse() do
      {:ok, {probe, pid}}
    else
      _error ->
        Process.sleep(25)
        eventually_read_probe(probe_path, pid_path, attempts - 1)
    end
  end

  defp eventually_read_probe(_probe_path, _pid_path, 0), do: :error
end
