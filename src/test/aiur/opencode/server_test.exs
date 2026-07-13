defmodule Aiur.Opencode.ServerTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{ApiClient, Server, TokenRegistry, WorkspaceSetup}

  test "ticket-directory sessions resolve the slot provider" do
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

    on_exit(fn ->
      restore_env(original_env)
      TokenRegistry.delete(token)
      File.rm_rf(root)
    end)

    {:ok, server} =
      Server.start_link(%{
        identifier: "_slot-#{slot_index}",
        workspace: slot_workspace
      })

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
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

      assert Enum.any?(providers, fn provider ->
               provider["id"] == "aiur" and Map.has_key?(provider["models"], "issue-99")
             end)
    after
      assert :ok = ApiClient.delete_session(base_url, session["id"])
    end
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
