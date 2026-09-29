defmodule Aiur.Workspace.PreflightReuseTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{AuthPreflight, Config}
  alias Aiur.WorkflowStore
  alias Aiur.Workspace.Hooks

  defmodule CountingClient do
    alias Aiur.GitHub.AuthPreflight

    def preflight_auth, do: AuthPreflight.preflight_auth(options())
    def ensure_preflight, do: AuthPreflight.ensure_preflight(options())

    defp options do
      [
        request_fun: fn request ->
          Process.put(:preflight_requests, [request.url | Process.get(:preflight_requests, [])])

          case Process.get(:fixture_hold) do
            nil -> {:ok, %{status: 200, headers: [], body: %{}}}
            hold -> {:error, {:aiur, :locally_held, hold}}
          end
        end,
        local_hold_max_waits: 0,
        gh_auth_status_fun: fn -> {:ok, :not_installed} end
      ]
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "preflight-reuse-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "config")
    File.write!(path, "tracker:\n  kind: github\n  github:\n    repo: owner/repo\n")
    keys = [:workflow_file_path, :github_client_module, :workspace_github_preflight_enabled, :workspace_github_preflight_fun]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:aiur, &1)})
    token = System.get_env("GITHUB_TOKEN")
    token_keys = [{Config, :resolved_token}, {Config, :resolved_token_source}]
    cached = Enum.map(token_keys, &{&1, :persistent_term.get(&1, :unset)})

    Application.put_env(:aiur, :workflow_file_path, path)
    Application.put_env(:aiur, :github_client_module, CountingClient)
    Application.put_env(:aiur, :workspace_github_preflight_enabled, true)
    Application.delete_env(:aiur, :workspace_github_preflight_fun)
    System.put_env("GITHUB_TOKEN", "fixture-preflight-token")
    Enum.each(token_keys, &:persistent_term.erase/1)
    AuthPreflight.invalidate(:test)
    reload_if_running()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      if token, do: System.put_env("GITHUB_TOKEN", token), else: System.delete_env("GITHUB_TOKEN")

      Enum.each(cached, fn
        {key, :unset} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)

      AuthPreflight.invalidate(:test_teardown)
      reload_if_running()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "workspace starts reuse the daemon's proven credential without more HTTP requests", %{root: root} do
    assert :ok = CountingClient.ensure_preflight()
    assert length(Process.get(:preflight_requests)) == 3
    assert :ok = Hooks.run_github_preflight(Path.join(root, "one"), %{}, nil)
    assert :ok = Hooks.run_github_preflight(Path.join(root, "two"), %{}, nil)
    assert length(Process.get(:preflight_requests)) == 3
  end

  test "credential replacement and a 401 each revalidate before workspace reuse", %{root: root} do
    assert :ok = Hooks.run_github_preflight(root, %{}, nil)
    assert length(Process.get(:preflight_requests)) == 3

    System.put_env("GITHUB_TOKEN", "replacement-fixture-token")
    assert :ok = Hooks.run_github_preflight(root, %{}, nil)
    assert length(Process.get(:preflight_requests)) == 6
    assert :ok = Hooks.run_github_preflight(root, %{}, nil)
    assert length(Process.get(:preflight_requests)) == 6

    AuthPreflight.note_response(%{token: "replacement-fixture-token"}, {:ok, %{status: 401}})
    assert :ok = Hooks.run_github_preflight(root, %{}, nil)
    assert length(Process.get(:preflight_requests)) == 9
    assert :ok = Hooks.run_github_preflight(root, %{}, nil)
    assert length(Process.get(:preflight_requests)) == 9
  end

  test "failed workspace proofs remain failures until a successful recheck", %{root: root} do
    Process.put(:fixture_hold, %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 3_600)})

    for _ <- 1..2 do
      assert {:error, {:workspace_github_connectivity_failed, ^root, {:github_auth_preflight_failed, %{classification: :local_hold}}}} =
               Hooks.run_github_preflight(root, %{}, nil)
    end

    assert length(Process.get(:preflight_requests)) == 2
    Process.delete(:fixture_hold)
    assert :ok = Hooks.run_github_preflight(root, %{}, nil)
    assert length(Process.get(:preflight_requests)) == 5
    assert :ok = Hooks.run_github_preflight(root, %{}, nil)
    assert length(Process.get(:preflight_requests)) == 5
  end

  defp reload_if_running do
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()
  end
end
