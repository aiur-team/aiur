defmodule Aiur.Opencode.ServerTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{ApiClient, Server, TokenRegistry, WorkspaceSetup}

  test "ticket-directory sessions resolve the slot provider" do
    root = Path.join(System.tmp_dir!(), "aiur-opencode-server-test-#{System.unique_integer([:positive, :monotonic])}")
    slot_workspace = Path.join(root, "slot")
    ticket_workspace = Path.join(root, "ticket")
    File.mkdir_p!(ticket_workspace)
    File.mkdir_p!(Path.join([System.user_home!(), ".local", "share", "opencode", "log"]))

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

    assert {:ok, session} =
             ApiClient.create_session(base_url, "99",
               model: %{providerID: "aiur", id: "issue-99"},
               directory: ticket_workspace
             )

    assert session["directory"] == ticket_workspace
    refute File.exists?(Path.join(ticket_workspace, "opencode.json"))

    assert {:ok, %Req.Response{status: 200, body: %{"all" => providers}}} =
             Req.get(base_url <> "/provider", params: [directory: ticket_workspace])

    assert Enum.any?(providers, fn provider ->
             provider["id"] == "aiur" and Map.has_key?(provider["models"], "issue-99")
           end)
  end
end
