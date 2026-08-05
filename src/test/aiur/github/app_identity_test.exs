defmodule Aiur.GitHub.AppIdentityTest do
  @moduledoc """
  A GitHub App installation token authenticates as the App's bot user
  (`<slug>[bot]`), not as the PAT account the daemon used before. Every
  identity-keyed gate compares an event actor against `tracker.github.bot_account`,
  so the migration is only safe if that value names the App bot.

  These tests pin both halves: the misconfiguration is detected and alerted,
  and self-loop suppression genuinely works when `bot_account` is an App bot login.
  """

  # async: false — mutates the GITHUB_APP_* env vars and the workflow file.
  use Aiur.TestSupport, async: false

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.{AppTokenRefresher, Config}
  alias Aiur.Workflow

  @app_bot_login "aiur-daemon[bot]"
  @app_id "12345"
  @installation_id "67890"

  defp pem do
    {_map, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:rsa, 2048}))
    pem
  end

  defp put_app_credentials do
    System.put_env("GITHUB_APP_ID", @app_id)
    System.put_env("GITHUB_APP_INSTALLATION_ID", @installation_id)
    System.put_env("GITHUB_APP_PRIVATE_KEY", pem())
  end

  defp write_config!(bot_account) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: bot_account
    )
  end

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      System.delete_env("GITHUB_APP_ID")
      System.delete_env("GITHUB_APP_INSTALLATION_ID")
      System.delete_env("GITHUB_APP_PRIVATE_KEY")
      System.delete_env("GITHUB_APP_PRIVATE_KEY_PATH")
      restore_env("GITHUB_TOKEN", previous_token)

      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      Publisher.set_tracked_fn(fn _ -> true end)
    end)

    :ok
  end

  describe "app_identity_issue/0" do
    test "flags a bot_account still naming the PAT account under App auth" do
      write_config!("its-applekid")
      put_app_credentials()

      assert Config.app_identity_issue() == {:bot_account_not_app_bot, "its-applekid"}
    end

    test "flags an unset bot_account under App auth" do
      write_config!(nil)
      put_app_credentials()

      assert Config.app_identity_issue() == :bot_account_missing
    end

    test "accepts a bot_account naming the App bot" do
      write_config!(@app_bot_login)
      put_app_credentials()

      assert Config.app_identity_issue() == nil
    end

    test "stays silent on the PAT path, where the PAT account is the right identity" do
      write_config!("its-applekid")

      assert Config.app_identity_issue() == nil
    end
  end

  describe "AppTokenRefresher identity alert" do
    test "emits a needs-attention alert when bot_account is not the App bot" do
      write_config!("its-applekid")
      put_app_credentials()
      AppTokenRefresher.clear_token()

      test_pid = self()
      emit_fun = fn topic, message, opts -> send(test_pid, {:alert, topic, message, opts}) end

      # The exchange fails; the identity check runs at init regardless of
      # whether a token could be acquired.
      request_fun = fn _request -> {:error, :econnrefused} end

      name = :"app_identity_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = AppTokenRefresher.start_link(name: name, request_fun: request_fun, emit_fun: emit_fun)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:alert, "system.github_app_token.identity_mismatch", message, opts}, 2_000
      assert Keyword.get(opts, :needs_attention) == true
      assert message =~ "its-applekid"
      assert message =~ "[bot]"
    end

    test "stays quiet when bot_account already names the App bot" do
      write_config!(@app_bot_login)
      put_app_credentials()
      AppTokenRefresher.clear_token()

      test_pid = self()
      emit_fun = fn topic, message, opts -> send(test_pid, {:alert, topic, message, opts}) end
      request_fun = fn _request -> {:error, :econnrefused} end

      name = :"app_identity_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = AppTokenRefresher.start_link(name: name, request_fun: request_fun, emit_fun: emit_fun)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      refute_receive {:alert, "system.github_app_token.identity_mismatch", _, _}, 300
    end

    test "stays quiet on the PAT path" do
      write_config!("its-applekid")
      AppTokenRefresher.clear_token()

      test_pid = self()
      emit_fun = fn topic, message, opts -> send(test_pid, {:alert, topic, message, opts}) end

      name = :"app_identity_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AppTokenRefresher.start_link(
          name: name,
          request_fun: fn _ -> flunk("disabled refresher must not request") end,
          emit_fun: emit_fun
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      refute_receive {:alert, "system.github_app_token.identity_mismatch", _, _}, 300
    end
  end

  describe "self-loop suppression under an App-token identity" do
    setup do
      write_config!(@app_bot_login)
      put_app_credentials()
      :ok
    end

    test "drops events authored by the App bot" do
      :ok = Exchange.subscribe("ticket.42.#")

      assert :filtered = Publisher.publish("ticket.42.issue.commented", %{}, actor: @app_bot_login)
      refute_receive {:event, _}, 100
    end

    test "the [bot] suffix survives the case-insensitive comparison" do
      assert :filtered = Publisher.publish("ticket.42.issue.commented", %{}, actor: "Aiur-Daemon[bot]")
    end

    test "a human actor still publishes" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      assert {:ok, _id, _count} = Publisher.publish("ticket.42.issue.commented", %{}, actor: "some-human")
      assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    end
  end
end
