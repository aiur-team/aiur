defmodule Aiur.Config.BackendCatalogTest do
  use Aiur.TestSupport

  alias Aiur.Config
  alias Aiur.Config.BackendCatalog
  alias Aiur.Config.Schema.Agent

  defmodule CustomCatalog do
    def known_backends, do: ["test"]
    def configurable_backends, do: ["test"]
    def default_config_backend, do: "test"
    def dispatchable_backends(_configs), do: ["test"]
    def config_validator(_backend), do: nil
    def rate_limit_fallback_targets, do: []
    def ambiguous_model_alias?(_backend, _model), do: false
    def model_required?(_backend), do: false
  end

  setup do
    previous = Application.fetch_env(:aiur, :backend_catalog)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :backend_catalog, value)
        :error -> Application.delete_env(:aiur, :backend_catalog)
      end
    end)
  end

  test "validation reports backend_catalog_unavailable when no provider is configured" do
    for missing <- [:absent, nil] do
      if missing == :absent,
        do: Application.delete_env(:aiur, :backend_catalog),
        else: Application.put_env(:aiur, :backend_catalog, nil)

      assert BackendCatalog.impl() == {:error, :backend_catalog_unavailable}
      assert BackendCatalog.default_backend() == {:error, :backend_catalog_unavailable}
      assert BackendCatalog.known_backends() == {:error, :backend_catalog_unavailable}
      assert Config.agent_kind() == {:error, :backend_catalog_unavailable}
      assert Config.rate_limit_fallback_backend() == {:error, :backend_catalog_unavailable}
      assert Config.settings_from({:ok, %{config: %{}}}) == {:error, :backend_catalog_unavailable}

      changeset = Agent.changeset(%Agent{}, %{"priority" => ["codex"], "routing" => %{"1" => "codex"}})
      refute changeset.valid?
      assert {"backend_catalog_unavailable", metadata} = Keyword.fetch!(changeset.errors, :backend_configs)
      assert metadata[:reason] == :backend_catalog_unavailable
    end
  end

  test "memoized settings do not hide a removed backend catalog" do
    ensure_workflow_store_running()
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")
    assert {:ok, %{agent: %{kind: "codex"}}} = Config.settings()

    Application.put_env(:aiur, :backend_catalog, nil)
    assert Config.settings() == {:error, :backend_catalog_unavailable}

    Application.put_env(:aiur, :backend_catalog, Aiur.CodingAgent.ConfigCatalog)
    assert {:ok, %{agent: %{kind: "codex"}}} = Config.settings()
  end

  test "config preparation and changeset validation read the registered catalog at call time" do
    Application.put_env(:aiur, :backend_catalog, CustomCatalog)

    assert {:ok, settings} =
             Config.settings_from({:ok, %{config: %{"agent" => %{"priority" => ["test"], "rate_limit_primary" => "test", "rate_limit_fallback" => ""}}}})

    assert settings.agent.kind == "test"
    assert settings.agent.priority == ["test"]

    invalid = Agent.changeset(%Agent{}, %{"priority" => ["codex"], "rate_limit_fallback" => ""})
    assert {message, _metadata} = Keyword.fetch!(invalid.errors, :priority)
    assert message == "contains an unknown backend \"codex\"; known backends: [\"test\"] (optionally backend:model)"
  end
end
