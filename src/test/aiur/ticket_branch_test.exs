defmodule Aiur.TicketBranchTest do
  use ExUnit.Case, async: true

  alias Aiur.TicketBranch

  describe "branch_name/2" do
    test "uses the first four normalized title words" do
      assert TicketBranch.branch_name(123, "Add New Test Cases for Hooks") ==
               "aiur/123-add-new-test-cases"
    end

    test "normalizes punctuation, separators, and common non-ASCII Latin letters" do
      assert TicketBranch.branch_name(123, "  Café—Straße / Æsir & Øresund  ") ==
               "aiur/123-cafe-strasse-aesir-oresund"
    end

    test "falls back to the legacy branch for an unusable title" do
      assert TicketBranch.branch_name(123, "— 😺 ***") == "aiur/123"
    end
  end

  describe "ticket_id/1" do
    test "parses legacy and suffixed ticket branches" do
      assert TicketBranch.ticket_id("aiur/123") == "123"
      assert TicketBranch.ticket_id("aiur/123-add-new-test-cases") == "123"
    end

    test "rejects malformed or unrelated branches" do
      for branch <- [
            "aiur/0",
            "aiur/123x",
            "aiur/123-",
            "aiur/123--slug",
            "aiur/123/slug",
            "aiur/abc",
            "feature/123"
          ] do
        assert TicketBranch.ticket_id(branch) == nil
      end
    end
  end

  describe "ticket_id_from_ref/1" do
    test "parses only heads refs for ticket branches" do
      assert TicketBranch.ticket_id_from_ref("refs/heads/aiur/123-add-new-test-cases") == "123"
      assert TicketBranch.ticket_id_from_ref("refs/heads/aiur/123") == "123"
      assert TicketBranch.ticket_id_from_ref("refs/tags/aiur/123-add-new-test-cases") == nil
    end
  end
end
