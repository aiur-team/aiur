defmodule Aiur.ControlCli.DispatchAccountTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCli.DispatchAccount

  test "names the backend account and the headroom scores" do
    row = %{backend: "claude", account: "everdred", account_selection_reason: "headroom: claude/everdred=64%; alternatives codex=5%"}
    assert DispatchAccount.suffix(row) == " [account claude/everdred; headroom: claude/everdred=64%; alternatives codex=5%]"
  end

  test "shows the headroom scores for a backend with one implicit account" do
    assert DispatchAccount.suffix(%{backend: "codex", account: nil, account_selection_reason: "headroom: codex=80%"}) == " [headroom: codex=80%]"
  end

  test "prints the account alone, and nothing for a row without account facts" do
    assert DispatchAccount.suffix(%{backend: "claude", account: "max"}) == " [account claude/max]"
    assert DispatchAccount.suffix(%{identifier: "T-1"}) == ""
  end
end
