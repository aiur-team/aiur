defmodule Aiur.GitHub.Access.SettingsTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Access.{Settings, StaticSettings}
  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.ReadCache.Policy
  alias Aiur.GitHub.ResourceStore.Memory
  alias Aiur.GitHub.Transport

  defmodule CountingProvider do
    def settings do
      count = Process.get({__MODULE__, :calls}, 0) + 1
      Process.put({__MODULE__, :calls}, count)
      send(Process.get({__MODULE__, :test_pid}), {:settings_call, count})
      %Aiur.GitHub.Access.Settings{state_root: "/tmp/settings-#{count}", repo: "owner/repo-#{count}"}
    end
  end

  setup do
    for key <- [:github_access_settings_provider, :github_access_settings] do
      previous = Application.fetch_env(:aiur, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end)
    end

    :ok
  end

  @tag :tmp_dir
  test "static settings return the supplied struct on each call", %{tmp_dir: root} do
    Application.put_env(:aiur, :github_access_settings_provider, StaticSettings)
    settings = Settings.new(root, budget: %{max_inflight: 7})
    Application.put_env(:aiur, :github_access_settings, settings)
    assert Settings.current() == settings
    Application.put_env(:aiur, :github_access_settings, %{settings | budget: %{max_inflight: 9}})
    assert Settings.current().budget.max_inflight == 9
  end

  test "an unregistered provider names the missing configuration" do
    Application.delete_env(:aiur, :github_access_settings_provider)
    assert_raise ArgumentError, ~r/github_access_settings_provider/, fn -> Settings.current() end
  end

  test "a request reuses one provider snapshot and restores the outer context" do
    test_pid = self()

    Process.put({CountingProvider, :test_pid}, test_pid)
    Application.put_env(:aiur, :github_access_settings_provider, CountingProvider)

    assert :result =
             Settings.with_request(fn ->
               assert Settings.current().repo == "owner/repo-1"
               assert Transport.base_url() == "https://api.github.com"
               assert Transport.parse_repo() == {:ok, {"owner", "repo-1"}}
               assert Budget.enabled?()
               assert Policy.ttl_ms(:issue) == 30_000
               assert Memory.max_body_bytes() == 128 * 1024 * 1024
               assert Settings.current().repo == "owner/repo-1"
               :result
             end)

    assert_received {:settings_call, 1}
    refute_received {:settings_call, 2}
    assert Settings.current().repo == "owner/repo-2"
    assert_received {:settings_call, 2}
  end

  @tag :tmp_dir
  test "stores and broker run in a fresh VM without Aiur.Application", %{tmp_dir: root} do
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    script = Path.expand("../../../fixtures/github_access_standalone.exs", __DIR__)
    {output, status} = System.cmd(System.find_executable("elixir"), paths ++ [script, root], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "standalone GitHub access passed"
  end
end
