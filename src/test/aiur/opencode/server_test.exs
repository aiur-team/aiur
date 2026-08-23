defmodule Aiur.Opencode.ServerTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{ApiClient, Server, TokenRegistry, WorkspaceSetup}
  alias Exqlite.Basic

  test "launch_env clears shell startup hooks" do
    assert {~c"BASH_ENV", false} in Server.launch_env("/workspace")
    assert {~c"ENV", false} in Server.launch_env("/workspace")
    assert {~c"ZDOTDIR", ~c"/dev/null"} in Server.launch_env("/workspace")
  end

  test "ticket-directory prompt resolves the slot provider and persists" do
    root = Path.join(System.tmp_dir!(), "aiur-opencode-server-test-#{System.unique_integer([:positive, :monotonic])}")
    slot_workspace = Path.join(root, "slot")
    ticket_workspace = Path.join(root, "ticket")
    poison_config_path = Path.join(root, "poison.json")
    xdg_data_home = Path.join(root, "xdg-data")
    File.mkdir_p!(ticket_workspace)
    File.mkdir_p!(Path.join([xdg_data_home, "opencode", "log"]))

    poison_config =
      Jason.encode!(%{
        "provider" => %{
          "aiur" => %{
            "name" => "poison parent",
            "npm" => "@ai-sdk/openai-compatible",
            "options" => %{"baseURL" => "http://127.0.0.1:9"},
            "models" => %{}
          }
        }
      })

    File.write!(poison_config_path, poison_config)

    child_env = %{
      "OPENCODE_CONFIG" => poison_config_path,
      "OPENCODE_CONFIG_CONTENT" => poison_config,
      "XDG_CACHE_HOME" => Path.join(root, "xdg-cache"),
      "XDG_CONFIG_HOME" => Path.join(root, "xdg-config"),
      "XDG_DATA_HOME" => xdg_data_home,
      "XDG_STATE_HOME" => Path.join(root, "xdg-state")
    }

    original_env = Map.new(child_env, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(child_env)

    on_exit(fn ->
      restore_env(original_env)
      File.rm_rf(root)
    end)

    slot_index = System.unique_integer([:positive])

    {:ok, token} =
      WorkspaceSetup.materialize_slot(
        slot_workspace,
        "http://127.0.0.1:1",
        ["99"],
        slot_index,
        1,
        display_identifier: "99"
      )

    on_exit(fn -> TokenRegistry.delete(token) end)

    {:ok, server} =
      Server.start_link(%{
        identifier: "_slot-#{slot_index}",
        workspace: slot_workspace
      })

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(server)
    end)

    assert {:ok, base_url, _os_pid} = Server.await_ready(server)

    assert System.get_env("OPENCODE_CONFIG") == poison_config_path
    assert System.get_env("OPENCODE_CONFIG_CONTENT") == poison_config

    assert {:ok, session} =
             ApiClient.create_session(base_url, "99",
               model: %{providerID: "aiur", id: "issue-99"},
               directory: ticket_workspace
             )

    try do
      assert session["directory"] == ticket_workspace
      refute File.exists?(Path.join(ticket_workspace, "opencode.json"))

      assert {:ok, %Req.Response{status: 200, body: %{"all" => providers}}} =
               Req.get(base_url <> "/provider", params: [directory: ticket_workspace])

      assert %{
               "name" => "Aiur",
               "options" => %{"baseURL" => "http://127.0.0.1:1/v1"},
               "models" => models
             } = Enum.find(providers, &(&1["id"] == "aiur"))

      assert Map.has_key?(models, "issue-99")

      # SessionPrompt persists the user message before it waits for the model
      # stream. Keep that production request in flight and inspect the real
      # schema rather than waiting for our intentionally unavailable bridge.
      prompt_task =
        Task.async(fn ->
          ApiClient.post_message(base_url, session["id"], %{parts: [%{type: "text", text: "operator regression prompt"}]})
        end)

      assert seq = await_session_message_seq(Path.join([xdg_data_home, "opencode", "opencode.db"]), session["id"])
      assert is_integer(seq) and seq >= 0

      Task.shutdown(prompt_task, :brutal_kill)
    after
      assert :ok = ApiClient.delete_session(base_url, session["id"])
    end
  end

  defp await_session_message_seq(db_path, session_id, attempts \\ 40)

  defp await_session_message_seq(_db_path, _session_id, 0), do: flunk("SessionPrompt did not persist session_message.seq")

  defp await_session_message_seq(db_path, session_id, attempts) do
    seq =
      case Basic.open(db_path) do
        {:ok, conn} ->
          try do
            case Basic.rows(Basic.exec(conn, "SELECT seq FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT 1", [session_id])) do
              {:ok, [[seq]], _} when is_integer(seq) -> seq
              _ -> nil
            end
          after
            Basic.close(conn)
          end

        _ ->
          nil
      end

    if is_integer(seq) do
      seq
    else
      Process.sleep(50)
      await_session_message_seq(db_path, session_id, attempts - 1)
    end
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  describe "release environment scrub on the opencode launch" do
    test "serve_command routes the launch through the shared scrub and execs opencode-serve" do
      command = Server.serve_command("127.0.0.1")

      assert command =~ "AIUR_RELEASE_DIR"
      assert command =~ "RELEASE_NODE"
      assert command =~ "RELEASE_COOKIE"
      assert command =~ ~r/; exec opencode serve --port 0 --hostname 127\.0\.0\.1/
    end

    test "the opencode child env excludes release launcher and distribution variables" do
      release_root = Path.join(System.tmp_dir!(), "aiur-opencode-release-#{System.unique_integer([:positive])}")
      release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
      release_bin = Path.join(release_root, "bin")
      File.mkdir_p!(release_erts_bin)
      File.mkdir_p!(release_bin)
      on_exit(fn -> File.rm_rf!(release_root) end)

      command = Server.serve_command("127.0.0.1")

      # `Port.open`'s partial :env list is merged OVER the inherited daemon env,
      # so the release vars can only be cleared by the command prefix. Prove the
      # exact launch shape clears them: reuse the server's scrubbed command but
      # exec a probe that prints the child env instead of the opencode binary.
      [scrub_prefix | _rest] = String.split(command, "; exec ")
      refute scrub_prefix =~ "exec opencode"

      probe =
        scrub_prefix <>
          "; exec sh -c 'env | grep -E \"^(ROOTDIR|BINDIR|EMU|PROGNAME|RELEASE_NODE|RELEASE_COOKIE)=\" | sort; true'"

      {output, 0} =
        System.cmd("bash", ["-c", probe],
          env: [
            {"AIUR_RELEASE_DIR", release_root},
            {"ROOTDIR", release_root},
            {"BINDIR", release_erts_bin},
            {"EMU", "beam"},
            {"PROGNAME", "erl"},
            {"RELEASE_NODE", "aiur@test"},
            {"RELEASE_COOKIE", "secret"},
            {"PATH", Enum.join([release_erts_bin, release_bin, System.fetch_env!("PATH")], ":")}
          ]
        )

      assert output == ""
    end
  end

  describe "serve child stdio and reaping" do
    test "port_opts routes the child's stderr through the port instead of inheriting the suite's" do
      # #2340: without :stderr_to_stdout the opencode child inherits the BEAM's
      # stderr, so a leaked (or slowly-reaped) serve keeps the suite's own pipe
      # open and a piped `mix test | cat` never sees EOF past the summary. Every
      # other long-lived Port.open launch (codex app-server, model discovery,
      # GitHub budget probe) already isolates stdio this way; opencode was missed.
      opts = Server.port_opts("/workspace", "opencode serve --port 0")

      assert :binary in opts
      assert :exit_status in opts
      assert :stderr_to_stdout in opts
      assert Keyword.fetch!(opts, :cd) == "/workspace"
      assert Keyword.fetch!(opts, :args) == ["-c", "opencode serve --port 0"]
    end

    test "server reaps its opencode child when stopped" do
      root = prepare_serve_root()
      on_exit(root.cleanup)

      %{server: server, os_pid: os_pid} = boot_serve(root)

      :ok = GenServer.stop(server)

      assert eventually(fn -> not process_alive?(os_pid) end),
             "opencode serve pid #{inspect(os_pid)} survived a graceful stop"
    end

    test "server reaps its opencode child when the owning process dies" do
      # The pre-fix leak: an ExUnit test process exits and its start_link'd
      # server is torn down by link teardown *before* on_exit's GenServer.stop
      # runs, so terminate/2 never reaped the serve and `opencode serve` was
      # orphaned to outlive the suite (#2340). The server now traps exits, so
      # the owner's death lands in terminate/2 and the child is reaped.
      root = prepare_serve_root()
      on_exit(root.cleanup)

      parent = self()

      {owner, ref} =
        spawn_monitor(fn ->
          {:ok, server} =
            Server.start_link(%{identifier: "_reap-#{System.unique_integer([:positive])}", workspace: root.workspace})

          {:ok, _base_url, os_pid} = Server.await_ready(server)
          send(parent, {:serve_up, server, os_pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:serve_up, server, os_pid}, 40_000

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 5_000

      assert eventually(fn -> not process_alive?(os_pid) end),
             "opencode serve pid #{inspect(os_pid)} survived its owner's death"

      refute Process.alive?(server)
    end

    test "a trapped-exit message from a dying linked process is swallowed, not a crash" do
      # trap_exit is on so terminate/2 runs on owner death; that also delivers
      # an `{:EXIT, _, _}` message for every dying linked non-parent process
      # (the opencode child's port closing, another linked process). Without a
      # clause the GenServer default handler raises FunctionClauseError on the
      # first trapped exit, turning a clean shutdown into a crash report
      # (#2340 review). The server must swallow it and keep serving. (An
      # `{:EXIT, parent, _}` is intercepted by gen_server itself, so the
      # message must carry a non-parent pid to reach handle_info/2.)
      root = prepare_serve_root()
      on_exit(root.cleanup)

      %{server: server, os_pid: os_pid} = boot_serve(root)

      other = spawn(fn -> :ok end)
      send(server, {:EXIT, other, :some_reason})

      # The call is queued behind the EXIT message, so it only succeeds if the
      # handler swallowed the EXIT first.
      assert {:ok, _base_url, ^os_pid} = Server.await_ready(server)
      assert Process.alive?(server)

      :ok = GenServer.stop(server)
    end

    test "reap escalates past a SIGTERM-ignoring serve and targets its process group" do
      # #2340 review, M3: reverting the escalation (grace → SIGKILL) or
      # narrowing the group kill to a single pid both survive the other tests.
      # This pins both by booting a stub `opencode` that ignores SIGTERM and
      # spawns a child in its group: (a) the reap must escalate to SIGKILL
      # after @terminate_grace_ms, and (b) it must signal the *group* — the
      # stub's child dies too — not just the leader pid. The stub is a
      # Port.open spawn, so it is a session/group leader (os_pid == pgid),
      # exactly the shape the pgid guard must confirm before group-killing.
      root = prepare_serve_root()
      on_exit(root.cleanup)

      child_pid_file = Path.join(root.root, "stubborn-child.pid")

      stub_dir = Path.join(root.root, "stub-bin")
      File.mkdir_p!(stub_dir)
      stub = Path.join(stub_dir, "opencode")

      File.write!(stub, """
      #!/usr/bin/env bash
      trap '' TERM
      sleep 30 &
      echo $! > #{child_pid_file}
      echo "stub up"
      wait
      """)

      File.chmod!(stub, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", stub_dir <> ":" <> original_path)
      on_exit(fn -> System.put_env("PATH", original_path) end)

      {:ok, server} =
        Server.start_link(%{identifier: "_stubborn-#{System.unique_integer([:positive])}", workspace: root.workspace})

      {:os_pid, os_pid} = Port.info(:sys.get_state(server).port_ref, :os_pid)

      assert eventually(fn -> File.regular?(child_pid_file) end), "stub child never started"
      child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()
      assert process_alive?(child_pid)
      assert os_pid == process_group_id(os_pid)

      :ok = GenServer.stop(server)

      # SIGKILL escalation: the stub ignores TERM, so a grace-only reap leaves
      # it running. Poll well past @terminate_grace_ms (1s).
      assert eventually(fn -> not process_alive?(os_pid) end, 100),
             "SIGTERM-ignoring stub pid #{inspect(os_pid)} was never escalated to SIGKILL"

      # Group targeting: a single-pid reap would kill the leader but leave its
      # child (same pgid) orphaned.
      assert eventually(fn -> not process_alive?(child_pid) end, 100),
             "stub child pid #{inspect(child_pid)} survived a group reap"
    end
  end

  defp prepare_serve_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "aiur-opencode-reap-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(root, "slot")
    poison_config_path = Path.join(root, "poison.json")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join([root, "xdg-data", "opencode", "log"]))

    poison_config =
      Jason.encode!(%{
        "provider" => %{
          "aiur" => %{
            "name" => "poison parent",
            "npm" => "@ai-sdk/openai-compatible",
            "options" => %{"baseURL" => "http://127.0.0.1:9"},
            "models" => %{}
          }
        }
      })

    File.write!(poison_config_path, poison_config)

    child_env = %{
      "OPENCODE_CONFIG" => poison_config_path,
      "OPENCODE_CONFIG_CONTENT" => poison_config,
      "XDG_CACHE_HOME" => Path.join(root, "xdg-cache"),
      "XDG_CONFIG_HOME" => Path.join(root, "xdg-config"),
      "XDG_DATA_HOME" => Path.join(root, "xdg-data"),
      "XDG_STATE_HOME" => Path.join(root, "xdg-state")
    }

    original_env = Map.new(child_env, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(child_env)

    %{
      root: root,
      workspace: workspace,
      cleanup: fn ->
        restore_env(original_env)
        File.rm_rf(root)
      end
    }
  end

  defp boot_serve(root) do
    {:ok, server} =
      Server.start_link(%{identifier: "_reap-#{System.unique_integer([:positive])}", workspace: root.workspace})

    {:ok, _base_url, os_pid} = Server.await_ready(server)
    %{server: server, os_pid: os_pid}
  end

  defp process_alive?(pid) when is_integer(pid) and pid > 0 do
    {output, status} = System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)], stderr_to_stdout: true)
    # `kill -0` also succeeds for a zombie (terminated but not yet reaped), so
    # a kill -0-only liveness check would report a reaped group member as
    # surviving. ps reports the state directly: gone → non-zero status,
    # zombie → a stat starting with "Z". Only a non-zombie live process counts
    # as alive.
    status == 0 and not String.starts_with?(String.trim(output), "Z")
  end

  defp process_alive?(_pid), do: false

  # Same `ps -o pgid=` probe the production pgid guard uses; here it asserts
  # the Port.open stub is a process-group leader before we rely on group kills.
  defp process_group_id(pid) when is_integer(pid) and pid > 0 do
    {output, 0} = System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true)
    output |> String.trim() |> String.to_integer()
  end

  defp process_group_id(_pid), do: nil

  defp eventually(fun, attempts \\ 40)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
