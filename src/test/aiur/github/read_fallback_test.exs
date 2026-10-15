defmodule Aiur.GitHub.ReadFallbackTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{Config, Transport}

  @cache_key {Config, :resolved_token}
  @transport_test_options_key :github_transport_test_options

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@cache_key, :unset)
    previous_options = Application.get_env(:aiur, @transport_test_options_key)
    :persistent_term.erase(@cache_key)
    System.put_env("GITHUB_TOKEN", "config-token")
    Application.put_env(:aiur, @transport_test_options_key, plug: {Req.Test, __MODULE__})

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(@cache_key)
        token -> :persistent_term.put(@cache_key, token)
      end

      case previous_options do
        nil -> Application.delete_env(:aiur, @transport_test_options_key)
        options -> Application.put_env(:aiur, @transport_test_options_key, options)
      end
    end)

    :ok
  end

  test "watcher reads retry one 401 with the readiness credential" do
    prev_readiness = System.get_env("AIUR_CI_READINESS_TOKEN")
    System.put_env("AIUR_CI_READINESS_TOKEN", "readiness-token")
    on_exit(fn -> restore_env("AIUR_CI_READINESS_TOKEN", prev_readiness) end)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:authorization, authorization})

      if authorization == "Bearer config-token" do
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
      else
        Req.Test.json(conn, %{"ok" => true})
      end
    end)

    assert {:ok, %{status: 200}} =
             Transport.default_request_fun(%{
               method: :get,
               url: "https://api.github.com/repos/owner/repo/commits",
               caller: "main_watch_commits",
               token: "config-token"
             })

    assert_received {:authorization, "Bearer config-token"}
    assert_received {:authorization, "Bearer readiness-token"}
  end

  test "landing watcher GraphQL reads retry one 401 with readiness credential" do
    prev_readiness = System.get_env("AIUR_CI_READINESS_TOKEN")
    System.put_env("AIUR_CI_READINESS_TOKEN", "readiness-token")
    on_exit(fn -> restore_env("AIUR_CI_READINESS_TOKEN", prev_readiness) end)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:authorization, authorization})

      if authorization == "Bearer config-token" do
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
      else
        Req.Test.json(conn, %{"data" => %{"viewer" => %{"login" => "bot"}}})
      end
    end)

    assert {:ok, %{status: 200}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/graphql",
               caller: "landing_watch_observation",
               token: "config-token",
               body: %{"query" => "query { viewer { login } }"}
             })

    assert_received {:authorization, "Bearer config-token"}
    assert_received {:authorization, "Bearer readiness-token"}
  end

  test "watcher mutations never retry with readiness credential" do
    prev_readiness = System.get_env("AIUR_CI_READINESS_TOKEN")
    System.put_env("AIUR_CI_READINESS_TOKEN", "readiness-token")
    on_exit(fn -> restore_env("AIUR_CI_READINESS_TOKEN", prev_readiness) end)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:authorization, authorization})
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
    end)

    assert {:ok, %{status: 401, credential: "github_token"}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/graphql",
               caller: "landing_watch_enqueue",
               token: "config-token",
               body: %{"query" => "mutation { enqueue }"}
             })

    assert_received {:authorization, "Bearer config-token"}
    refute_received {:authorization, "Bearer readiness-token"}
  end
end
