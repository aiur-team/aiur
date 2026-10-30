defmodule Aiur.Executor.HookUrlBindTest do
  use Aiur.TestSupport
  alias Aiur.Executor.HookConfig

  test "HTTP binds rewrite the private hook URL with the actual port" do
    key = System.get_env("AIUR_INSTANCE_KEY")
    System.put_env("AIUR_INSTANCE_KEY", "hook-url-bind")
    url_path = HookConfig.url_path()

    on_exit(fn ->
      _ = File.rm(url_path)
      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
    end)

    File.mkdir_p!(Path.dirname(HookConfig.url_path()))
    File.write!(HookConfig.url_path(), "http://127.0.0.1:1")

    for _ <- 1..2 do
      assert {:ok, pid} = HttpServer.start_link(host: "127.0.0.1", port: 0, dashboard_writable: false)

      try do
        port = HttpServer.bound_port()
        assert is_integer(port) and port > 0
        assert File.read!(HookConfig.url_path()) == "http://127.0.0.1:#{port}"
        assert Bitwise.band(File.stat!(HookConfig.url_path()).mode, 0o777) == 0o600
      after
        Supervisor.stop(pid)
      end
    end
  end
end
