defmodule Aiur.Executor.HookUrlBindTest do
  use Aiur.TestSupport
  alias Aiur.Executor.HookConfig

  test "HTTP binds rewrite the private hook URL with the actual port" do
    key = System.get_env("AIUR_INSTANCE_KEY")
    System.put_env("AIUR_INSTANCE_KEY", "hook-url-bind")
    url_path = HookConfig.url_path()
    # HttpServer.start_link rewrites these app-wide (dashboard_auth_required: false here); later tests read them.
    previous_env = Map.new([AiurWeb.Endpoint, :dashboard_pages, :dashboard_url_fun], &{&1, Application.fetch_env(:aiur, &1)})

    on_exit(fn ->
      for {env_key, value} <- previous_env do
        case value do
          {:ok, previous} -> Application.put_env(:aiur, env_key, previous)
          :error -> Application.delete_env(:aiur, env_key)
        end
      end

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
