defmodule Aiur.Events.PrCommandScannerIdentityModeTest do
  @moduledoc """
  The `/aiur` command surface under both identity modes (#2501).

  The publisher gate is not the only place that decides "Aiur wrote this" from
  a login. `PrCommandScanner` drops Aiur's own `/aiur` comments the same way,
  and on a single-account install that login is the operator's — so without the
  marker check the operator's own commands are the ones being dropped.
  """
  use Aiur.TestSupport

  alias Aiur.Events.PrCommandScanner
  alias Aiur.GitHub.AgentMarker
  alias Aiur.Workflow

  @prefix "/aiur"
  @bot "aiur-bot"

  defp configure!(mode) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: @bot,
      tracker_identity_mode: mode
    )
  end

  defp comment(body, login) do
    %{
      "id" => 1,
      "body" => body,
      "user" => %{"login" => login},
      author_trusted?: true
    }
  end

  setup do
    # `identity_mode` lives in the shared workflow file, so leaving it at
    # `single_account` would silently reconfigure every later test in this
    # partition that does not write the file itself.
    on_exit(fn -> configure!("separate_account") end)
    :ok
  end

  describe "single-account mode" do
    setup do
      configure!("single_account")
      :ok
    end

    test "the operator's own /aiur command from the shared login is obeyed" do
      assert PrCommandScanner.command?(comment("/aiur rerun the failing job", @bot), @prefix, @bot)
    end

    test "a marked /aiur comment Aiur wrote itself is dropped" do
      body = "/aiur rerun the failing job\n\n" <> AgentMarker.marker()

      refute PrCommandScanner.command?(comment(body, @bot), @prefix, @bot)
    end

    test "an untrusted author is still refused regardless of the marker" do
      untrusted = %{comment("/aiur do it", @bot) | author_trusted?: false}

      refute PrCommandScanner.command?(untrusted, @prefix, @bot)
    end
  end

  describe "separate-account mode" do
    setup do
      configure!("separate_account")
      :ok
    end

    test "an unmarked /aiur comment from the bot login is still dropped" do
      refute PrCommandScanner.command?(comment("/aiur rerun the failing job", @bot), @prefix, @bot)
    end

    test "a human's /aiur comment is obeyed" do
      assert PrCommandScanner.command?(comment("/aiur rerun the failing job", "its-everdred"), @prefix, @bot)
    end
  end
end
