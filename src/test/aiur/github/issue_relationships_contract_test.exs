defmodule Aiur.GitHub.IssueRelationshipsContractTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.IssueRelationships

  test "linked PR fetch requires explicit options" do
    Code.ensure_loaded!(IssueRelationships)

    assert function_exported?(IssueRelationships, :fetch_linked_pull_requests, 3)
    refute function_exported?(IssueRelationships, :fetch_linked_pull_requests, 2)
  end
end
