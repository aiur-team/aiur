defmodule Aiur.Config.ProjectIdentitySourceTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  defmodule Source do
    @spec project_identity() :: String.t()
    def project_identity, do: "owner/project identity"
  end

  defmodule FailingSource do
    @spec project_identity() :: no_return()
    def project_identity, do: raise("unavailable")
  end

  setup do
    previous = Application.fetch_env(:aiur, :project_identity_source)

    on_exit(fn ->
      case previous do
        {:ok, source} -> Application.put_env(:aiur, :project_identity_source, source)
        :error -> Application.delete_env(:aiur, :project_identity_source)
      end
    end)

    :ok
  end

  test "repo_name uses the configured project identity source" do
    Application.put_env(:aiur, :project_identity_source, Source)
    assert Paths.repo_name() == "project_identity"
  end

  # Regression guard for the existing failure-safe repo name.
  test "a failing configured source preserves the failure-safe default" do
    Application.put_env(:aiur, :project_identity_source, FailingSource)
    assert Paths.repo_name() == "aiur"
  end
end
