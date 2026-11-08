defmodule Aiur.ClientTokensCLIMemoryTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias Aiur.Workflow
  alias AiurWeb.Router

  @session_options Plug.Session.init(store: :cookie, key: "_aiur_token_cli_test", signing_salt: "aiur-token-cli-test")
  @control_request %{
    "contract" => "aiur.control.call",
    "contract_version" => 1,
    "expression" => "Aiur.AgentControlCLI.executor_subscriptions()"
  }

  test "token created for a memory project authenticates against the control endpoint" do
    fixture_root = Workflow.workflow_file_path() |> Path.dirname() |> Path.dirname()
    project_root = Path.join(fixture_root, "memory-project")
    config_path = Aiur.TestSupport.prepare_workflow_file_path!(project_root)
    state_root = Path.join(fixture_root, "token-state")

    write_workflow_file!(config_path, tracker_kind: "memory")
    isolate_token_state(project_root, state_root)

    token =
      capture_io(fn ->
        assert :ok = Aiur.ClientTokensCLI.run(["create", "memory-control", "--scope", "read"])
      end)
      |> String.trim()

    assert File.regular?(token_store_path(state_root, "memory"))

    # The daemon loads the same memory-tracker config when it serves requests.
    :ok = Workflow.set_workflow_file_path(config_path)

    response = post_control(token)
    assert response.status == 200
    assert String.ends_with?(Jason.decode!(response.resp_body)["output"], "__AIUR_CONTROL_EXIT__:0\n")
  end

  defp isolate_token_state(project_root, state_root) do
    previous_project_root = System.get_env("AIUR_PROJECT_ROOT")
    previous_state_root = System.get_env("AIUR_BG_STATE_DIR")
    previous_instance_key = System.get_env("AIUR_INSTANCE_KEY")
    previous_decision_state_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_client_tokens_path = Application.get_env(:aiur, :client_tokens_path)
    previous_audit_path = Application.get_env(:aiur, :control_audit_file)

    on_exit(fn ->
      restore_system_env("AIUR_PROJECT_ROOT", previous_project_root)
      restore_system_env("AIUR_BG_STATE_DIR", previous_state_root)
      restore_system_env("AIUR_INSTANCE_KEY", previous_instance_key)
      restore_application_env(:decision_state_dir, previous_decision_state_dir)
      restore_application_env(:client_tokens_path, previous_client_tokens_path)
      restore_application_env(:control_audit_file, previous_audit_path)
    end)

    System.put_env("AIUR_PROJECT_ROOT", project_root)
    System.put_env("AIUR_BG_STATE_DIR", state_root)
    System.put_env("AIUR_INSTANCE_KEY", "memory-token-test")
    Application.delete_env(:aiur, :decision_state_dir)
    Application.delete_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :control_audit_file, Path.join(project_root, "control-audit.ndjson"))
  end

  defp token_store_path(state_root, project_leaf) do
    Path.join([state_root, System.fetch_env!("AIUR_INSTANCE_KEY"), project_leaf, "client-tokens.json"])
  end

  defp post_control(token) do
    conn =
      :post
      |> conn("/api/v1/control", Jason.encode!(@control_request))
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> AiurWeb.Session.call(@session_options)
      |> fetch_session()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))

    response = Router.call(conn, Router.init([]))

    receive do
      {:plug_conn, :sent} -> :ok
    after
      0 -> :ok
    end

    response
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
  defp restore_application_env(name, nil), do: Application.delete_env(:aiur, name)
  defp restore_application_env(name, value), do: Application.put_env(:aiur, name, value)
end
