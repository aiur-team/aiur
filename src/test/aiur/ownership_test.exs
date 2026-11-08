defmodule Aiur.OwnershipTest do
  use ExUnit.Case, async: true

  alias Aiur.Ownership

  test "ticket key: issue number, or pr-<N> for PR-anchored units" do
    assert Ownership.ticket_key(%{identifier: "42", pr_head_ref: nil}) == "42"
    assert Ownership.ticket_key(%{identifier: "77", pr_head_ref: "feat/x"}) == "pr-77"
  end

  test "disabled returns :disabled" do
    assert Ownership.ensure_owned(%{}, ownership_enabled: false) == :disabled
  end

  test "missing gateway identity declines as unknown, never invents an id" do
    issue = %{identifier: "1", pr_head_ref: nil, tracker_identity: nil}
    read = fn _, _, _ -> flunk("read") end

    assert {:declined, :unknown, _} =
             Ownership.ensure_owned(issue,
               ownership_enabled: true,
               ownership_self: nil,
               ownership_read_fun: read
             )
  end
end
