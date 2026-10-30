defmodule Aiur.Executor.DeliverHookCommandTest do
  use ExUnit.Case, async: true

  alias Aiur.Executor.DeliverHookCommand
  alias Aiur.Shell

  defmodule Stub do
    def init(opts), do: opts

    def call(conn, {owner, status}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn.request_path, conn.query_string, Plug.Conn.get_req_header(conn, "authorization"), body})
      Plug.Conn.send_resp(conn, status, if(status == 204, do: "", else: ~s({"delivery":"hello"})))
    end
  end

  setup do
    root = Aiur.TestSupport.tmp_root!("deliver ' $(echo unsafe)")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{token_path: Path.join(root, "token ' $(echo unsafe)")}
  end

  test "command preserves output, fails silently and has a three second budget", %{token_path: path} do
    command = DeliverHookCommand.command(:claude, "http://127.0.0.1:1234/", path)
    assert command =~ "-f"
    assert command =~ "-m 3"
    assert command =~ "; exit 0"
    refute command =~ "-o /dev/null"
    assert command =~ "/api/v1/executor/hook/deliver?harness=claude"
  end

  test "only Claude and Codex harnesses are accepted", %{token_path: path} do
    assert DeliverHookCommand.command(:codex, "http://127.0.0.1", path) =~ "harness=codex"
    assert_raise FunctionClauseError, fn -> DeliverHookCommand.command(:other, "http://127.0.0.1", path) end
  end

  test "missing token stays silent on authentication failure", %{token_path: path} do
    assert run(DeliverHookCommand.command(:claude, server(401), path)) == {"", 0}
    assert_receive {:request, "/api/v1/executor/hook/deliver", "harness=claude", ["Bearer"], ~s({"event":"Stop"})}, 1_000
  end

  test "runtime token is absent from curl arguments", %{token_path: path} do
    File.write!(path, "private-token")
    bin = Path.join(Path.dirname(path), "bin")
    File.mkdir_p!(bin)
    capture = Path.join(bin, "arguments")
    wrapper = Path.join(bin, "curl")
    File.write!(wrapper, "#!/bin/sh\nprintf '%s\\n' \"$@\" > " <> Shell.escape(capture) <> "\nexec " <> Shell.escape(System.find_executable("curl")) <> " \"$@\"\n")
    File.chmod!(wrapper, 0o700)
    command = DeliverHookCommand.command(:claude, server(200), path)
    assert run(command, env: [{"PATH", bin <> ":" <> System.get_env("PATH")}]) == {~s({"delivery":"hello"}), 0}
    refute File.read!(capture) =~ "private-token"
    assert_receive {:request, "/api/v1/executor/hook/deliver", "harness=claude", ["Bearer private-token"], ~s({"event":"Stop"})}, 1_000
  end

  test "200 body reaches stdout and stdin, harness, quoted URL and current token reach daemon", %{token_path: path} do
    base = server(200) <> "/quoted'$(id)"
    command = DeliverHookCommand.command(:codex, base, path)

    for token <- ["first-secret", "rotated-secret"] do
      File.write!(path, token)
      refute command =~ token
      assert run(command) == {~s({"delivery":"hello"}), 0}
      assert_receive {:request, "/quoted'$(id)/api/v1/executor/hook/deliver", "harness=codex", ["Bearer " <> ^token], ~s({"event":"Stop"})}, 1_000
    end
  end

  for status <- [204, 401, 500] do
    test "#{status} prints nothing and exits zero", %{token_path: path} do
      File.write!(path, "secret")
      command = DeliverHookCommand.command(:claude, server(unquote(status)), path)
      assert run(command) == {"", 0}
      assert_receive {:request, "/api/v1/executor/hook/deliver", "harness=claude", ["Bearer secret"], ~s({"event":"Stop"})}, 1_000
    end
  end

  test "connection refused exits zero without diagnostics", %{token_path: path} do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    assert run(DeliverHookCommand.command(:claude, "http://127.0.0.1:#{port}", path)) == {"", 0}
  end

  defp server(status) do
    server = start_supervised!({Bandit, plug: {Stub, {self(), status}}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp run(command, opts \\ []) do
    System.cmd("sh", ["-c", "printf '%s' " <> Shell.escape(~s({"event":"Stop"})) <> " | (" <> command <> ")"], Keyword.put(opts, :stderr_to_stdout, true))
  end
end
