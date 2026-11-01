defmodule Aiur.PrMerge.IdentityTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.Identity
  @github %{bot_account: "worker", github_app: %{account: "daemon[bot]"}, human_mergers: ["operator", "worker", "daemon[bot]"]}

  test "only listed human identities pass, excluding bot and App even if listed" do
    assert Identity.allowed(%{"login" => "OPERATOR", "type" => "User"}, @github, "separate_account") == :ok

    for login <- ["worker", "daemon[bot]", "stranger"] do
      assert {:refuse, [_]} = Identity.allowed(%{"login" => login, "type" => "User"}, @github, "separate_account")
    end

    assert {:refuse, ["GitHub identity is not a human user"]} = Identity.allowed(%{"login" => "operator", "type" => "Bot"}, @github, "separate_account")
    assert {:refuse, [message]} = Identity.allowed(%{"login" => "operator", "type" => "User"}, %{@github | human_mergers: []}, "separate_account")
    assert message =~ "tracker.github.human_mergers"
  end

  test "single account permits the listed bot login but still rejects Apps and unlisted users" do
    assert Identity.allowed(%{"login" => "WORKER", "type" => "User"}, @github, "single_account") == :ok
    assert {:refuse, [_]} = Identity.allowed(%{"login" => "daemon[bot]", "type" => "User"}, @github, "single_account")
    assert {:refuse, [_]} = Identity.allowed(%{"login" => "stranger", "type" => "User"}, @github, "single_account")
  end

  test "agent environment and canonical workspace containment refuse" do
    settings = %{workspace: %{root: Path.join(System.tmp_dir!(), "workspaces")}}
    assert {:refuse, [_]} = Identity.guard(settings, File.cwd!(), "")
    assert {:refuse, [_]} = Identity.guard(settings, Path.join(settings.workspace.root, "123"), nil)
    assert :ok = Identity.guard(settings, settings.workspace.root <> "-operator", nil)
  end
end
