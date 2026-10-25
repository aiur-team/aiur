defmodule Aiur.GitHub.Config.RepoAndSettingsTest do
  import Aiur.GitHub.Config.TestFixtures

  # async: false — these tests mutate the GITHUB_TOKEN env var and the shared
  # :persistent_term cache, so they must not run concurrently.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Config
  alias Aiur.Workflow

  import Aiur.TestSupport,
    only: [
      write_workflow_file_atomic!: 2,
      ensure_workflow_store_running: 0
    ]

  @cache_key {Aiur.GitHub.Access.Token, :resolved_token}
  @keyring_timeout_env "AIUR_GH_KEYRING_TIMEOUT_MS"
  @origin_cache_key {Config, :resolved_origin_repo}
  @source_cache_key {Aiur.GitHub.Access.Token, :resolved_token_source}

  setup do
    original = System.get_env("GITHUB_TOKEN")
    original_keyring_timeout = System.get_env(@keyring_timeout_env)

    on_exit(fn ->
      :persistent_term.erase(@cache_key)
      :persistent_term.erase(@source_cache_key)

      case original do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end

      case original_keyring_timeout do
        nil -> System.delete_env(@keyring_timeout_env)
        value -> System.put_env(@keyring_timeout_env, value)
      end
    end)

    :ok
  end

  # One `~/.aiur/config` shared by daemons for several repositories can name at
  # most one repo, so identity has to resolve the repository the daemon is
  # actually polling — the checkout's origin — when the key carries no value.
  # Without that, every issue normalized to an unjoinable identity and every
  # dispatch failed `:missing_tracker_identity` (#2518).
  describe "configured_repo/1" do
    setup do
      # The active workflow file is a VM-global path every async: false module
      # shares, so restore the exact bytes this module found rather than a
      # hardcoded value that would leave a different repo behind for whatever
      # runs next.
      path = Workflow.workflow_file_path()
      original = File.read!(path)

      on_exit(fn ->
        write_workflow_file_atomic!(path, original)
        ensure_workflow_store_running()
        :ok = Aiur.WorkflowStore.force_reload(5_000)
        :persistent_term.erase(@origin_cache_key)
      end)

      :persistent_term.erase(@origin_cache_key)

      :ok
    end

    test "an explicitly configured repository is used without consulting the origin remote" do
      write_tracker_repo!("acme/widgets")

      assert {:ok, {"acme", "widgets"}} = Config.configured_repo(refuting_origin())
    end

    test "an omitted repository falls back to the checkout's origin remote" do
      write_tracker_repo!(nil)

      assert {:ok, {"acme", "widgets"}} = Config.configured_repo(origin("acme/widgets"))
    end

    test "a blank repository falls back to the checkout's origin remote" do
      write_tracker_repo!("   ")

      assert {:ok, {"acme", "widgets"}} = Config.configured_repo(origin("acme/widgets"))
    end

    test "an omitted repository with no origin remote stays explicitly missing" do
      write_tracker_repo!(nil)

      assert {:error, :missing_configured_repository} = Config.configured_repo(origin(nil))
    end

    test "a malformed configured repository stays fail-closed and never falls back" do
      write_tracker_repo!("owner/repo/extra")

      assert {:error, :invalid_configured_repository} = Config.configured_repo(refuting_origin())
    end

    # An auto-detected slug is not operator-typed, so it gets the same parse as
    # a configured one rather than being trusted into an identity.
    test "a malformed origin remote is rejected rather than trusted" do
      write_tracker_repo!(nil)

      assert {:error, :invalid_configured_repository} = Config.configured_repo(origin("not-a-slug"))
    end

    # The #2518 defect was `repo/0` and `configured_repo/0` disagreeing about
    # which repository this daemon is on. Pin the agreement against an injected
    # origin so the property holds regardless of the checkout the suite runs in.
    test "configured_repo/0 and repo/0 resolve the same repository when the key is omitted" do
      write_tracker_repo!(nil)

      assert Config.repo(origin("acme/widgets")) == "acme/widgets"
      assert Config.configured_repo(origin("acme/widgets")) == {:ok, {"acme", "widgets"}}
    end

    test "configured_repo/0 and repo/0 resolve the same repository when the key is set" do
      write_tracker_repo!("  acme/widgets  ")

      assert Config.repo(refuting_origin()) == "acme/widgets"
      assert Config.configured_repo(refuting_origin()) == {:ok, {"acme", "widgets"}}
    end

    test "repo/0 falls back to the origin remote for a blank key, like configured_repo/0" do
      write_tracker_repo!("   ")

      assert Config.repo(origin("acme/widgets")) == "acme/widgets"
      assert Config.repo(origin(nil)) == nil
    end

    # #2518 cost two investigations and a recommendation to edit a healthy live
    # config, because the failure named no file: the operator read a repo-local
    # `.aiur/config` while the failing daemon read the global one. The
    # diagnostic must name the file that was read AND the paths searched, or the
    # next reader repeats the mistake.
    test "the resolution diagnostic names the config file read and every path searched" do
      write_tracker_repo!(nil)

      diagnostic = Config.repository_resolution_diagnostic()

      assert diagnostic =~ "config_read=#{Workflow.workflow_file_path()}"
      assert diagnostic =~ "tracker.github.repo=unset"

      # Every candidate, so a reader can see the repo-local path was searched
      # even when the global file is the one that won.
      for candidate <- Workflow.config_path_candidates() do
        assert diagnostic =~ candidate,
               "diagnostic must name searched path #{candidate}, got: #{diagnostic}"
      end

      assert Enum.any?(Workflow.config_path_candidates(), &String.ends_with?(&1, "/.aiur/config")),
             "the searched set must include the repo-local and global .aiur/config paths"
    end

    test "the resolution diagnostic reports a configured repository as the value read" do
      write_tracker_repo!("acme/widgets")

      assert Config.repository_resolution_diagnostic() =~ "tracker.github.repo=acme/widgets"
    end

    # `explicit_configured_repo/0` is what durable on-disk scoping reads, so it
    # must never take the fallback — see `Aiur.IssueLog.configured_repository_scope/0`.
    test "explicit_configured_repo/0 never falls back to the origin remote" do
      write_tracker_repo!(nil)

      assert {:error, :missing_configured_repository} = Config.explicit_configured_repo()

      write_tracker_repo!("acme/widgets")

      assert {:ok, {"acme", "widgets"}} = Config.explicit_configured_repo()
    end
  end
end
