defmodule Aiur.Extensions.WorkflowStoreTest do
  use Aiur.TestSupport

  import Aiur.ExtensionsTestSupport

  setup do
    linear_client_module = Application.get_env(:aiur, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:aiur, :linear_client_module)
      else
        Application.put_env(:aiur, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    # This test terminates the shared WorkflowStore singleton mid-body; restore
    # it in on_exit so a mid-test failure can't leak a down store to the next
    # sequential module (the #780 WorkspaceAndConfigTest flake).
    on_exit(fn -> ensure_workflow_store_running() end)
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()
    assert :ok = WorkflowStore.subscribe()
    first_generation = :sys.get_state(WorkflowStore).generation

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_receive {:workflow_config_updated, generation}, 1000
    assert generation > first_generation

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    assert {:ok, %{prompt: "Second prompt"}, ^generation} =
             WorkflowStore.current_with_generation()

    # Write the malformed config atomically: a plain `File.write!/2` truncates
    # first, and the store's background poll could read and commit the empty
    # intermediate (empty YAML parses to valid defaults) before the synchronous
    # reload below sees the malformed bytes — replacing last-known-good and
    # failing the "keeps last good workflow" guarantee (#1635).
    write_workflow_file_atomic!(Workflow.workflow_file_path(), "tracker: [\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "thirdconfig.yaml")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert {:ok, %{prompt: "Third prompt"}, :unknown} = WorkflowStore.current_with_generation()
    assert :ok = WorkflowStore.force_reload()
    assert :ok = ensure_workflow_store_running()
  end

  # Since #1731 a read never enters the store's mailbox, so there is no longer a
  # "read in flight when the store dies" window to trace. The guarantee that
  # test protected — a reader must get the config, not an exit — is now covered
  # by the two properties below: a suspended store does not block a read at all,
  # and a store that has gone away leaves no cache behind to serve.
  test "a suspended store does not block a read" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      ensure_workflow_store_running()
    end)

    :sys.suspend(store)

    reader = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> WorkflowStore.current() end)

    assert {:ok, %{prompt: "You are an agent for this repository."}} = Task.await(reader, 1_000)
    assert {:message_queue_len, 0} = Process.info(store, :message_queue_len)
  end

  test "workflow store falls back to the file when it has shut down" do
    ensure_workflow_store_running()
    on_exit(fn -> ensure_workflow_store_running() end)

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)
    refute Process.whereis(WorkflowStore)

    assert {:ok, %{prompt: "You are an agent for this repository."}} = WorkflowStore.current()
    assert {:ok, %{}, :unknown} = WorkflowStore.current_with_generation()
  end

  test "workflow store retries a transient parse failure during a config write" do
    ensure_workflow_store_running()
    path = Workflow.workflow_file_path()
    valid_config = File.read!(path)

    write_workflow_file_atomic!(path, "tracker: [\n")

    writer =
      Task.async(fn ->
        Process.sleep(75)
        File.write!(path, valid_config)
      end)

    assert :ok = WorkflowStore.force_reload()
    assert :ok = Task.await(writer)
  end

  test "workflow store reloads when only the prompt_file body changes" do
    ensure_workflow_store_running()
    original_path = Workflow.workflow_file_path()

    config_path = Path.join(Path.dirname(original_path), "prompt_reloadconfig.yaml")
    write_workflow_file!(config_path, prompt: "Original prompt body")
    Workflow.set_workflow_file_path(config_path)

    assert {:ok, %{prompt: "Original prompt body"}} = Workflow.current()

    # Edit only the referenced prompt_file; the config.yaml bytes are untouched.
    prompt_basename = String.trim_leading(Path.basename(config_path), ".") <> ".prompt.md"
    File.write!(Path.join(Path.dirname(config_path), prompt_basename), "Edited prompt body\n")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Edited prompt body"}}, Workflow.current())
    end)

    Workflow.set_workflow_file_path(original_path)
    WorkflowStore.force_reload()
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "missingconfig.yaml")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    # Terminates the shared WorkflowStore mid-body; restore it in on_exit so a
    # mid-test failure can't leak a down store to a later sequential module.
    on_exit(fn -> ensure_workflow_store_running() end)
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "manualconfig.yaml")
    missing_path = Path.join(Path.dirname(existing_path), "manual-missingconfig.yaml")

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    write_workflow_file_atomic!(manual_path, "tracker: [\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 5_000

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 5_000

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 5_000

    :ok = GenServer.stop(manual_pid)
    refute Process.alive?(manual_pid)

    Workflow.set_workflow_file_path(existing_path)

    assert :ok = ensure_workflow_store_running()
    restarted_pid = Process.whereis(WorkflowStore)
    assert Process.alive?(restarted_pid)

    WorkflowStore.force_reload()
  end
end
