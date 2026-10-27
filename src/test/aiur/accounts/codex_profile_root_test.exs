defmodule Aiur.Accounts.CodexProfileRootTest do
  use Aiur.TestSupport

  alias Aiur.Accounts.Shims.Codex

  test "the default Codex profile root follows the configured state-volume home" do
    previous = System.get_env("CODEX_HOME")
    codex_home = Path.join(System.tmp_dir!(), "aiur-codex-profile-#{System.unique_integer([:positive])}")
    System.put_env("CODEX_HOME", codex_home)

    on_exit(fn ->
      if previous, do: System.put_env("CODEX_HOME", previous), else: System.delete_env("CODEX_HOME")
    end)

    assert Codex.profile_root() == codex_home
  end
end
