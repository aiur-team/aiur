defmodule Aiur.AllowedContributors.ConfigReloadTest do
  use Aiur.TestSupport

  alias Aiur.AllowedContributors
  alias Aiur.AllowedContributorsFixture, as: Fixture

  test "real config reload updates the intake source and revokes the previous user" do
    path = Workflow.workflow_file_path()
    write_config(path, [42])
    assert Config.settings!().tracker.github.allowed_contributors == %{"users" => [42]}
    test = self()
    dir = Path.join(Path.dirname(path), "intake")

    server =
      start_supervised!(
        {AllowedContributors,
         name: nil,
         repo: {"acme", "app"},
         state_dir: dir,
         refresh_ms: :infinity,
         token_fun: fn -> nil end,
         request_fun: fn request -> flunk("config source fetched GitHub: #{inspect(request)}") end,
         publish_fun: fn _topic, _payload, _opts -> {:ok, 1, 1} end,
         alert_fun: fn name, message, _opts ->
           send(test, {:intake_alert, name, message})
           :ok
         end,
         aiur_logins_fun: fn -> [] end}
      )

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:intake_alert, "allowed_contributors.changed", _initial}
    write_config(path, [43])
    receive_barrier({:intake_alert, "allowed_contributors.changed", changed})
    assert changed =~ ~s(added ["user:43"])
    assert changed =~ ~s(removed ["user:42"])
    assert changed =~ "config -> config"
    assert {:reject, :not_allowed} = AllowedContributors.observe(Fixture.candidate(number: 102), server)
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 103, author_id: 43), server)
  end

  defp write_config(path, users) do
    write_workflow_file_atomic!(path, """
    tracker:
      kind: memory
      base_branch: main
      github:
        allowed_contributors:
          users: [#{Enum.join(users, ", ")}]
    """)

    ensure_workflow_store_running()
    :ok = WorkflowStore.force_reload()
  end
end
