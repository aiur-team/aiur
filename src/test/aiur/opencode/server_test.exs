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
    {_output, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp process_alive?(_pid), do: false

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
