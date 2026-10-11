defmodule Aiur.TestSupport.DispatchPolicyFixture do
  @moduledoc false
  alias Aiur.Issue

  def blocker(identifier, state) do
    %{id: identifier, identifier: identifier, state: state, url: nil}
  end

  def issue(id, attrs) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: id && "repo##{id}",
          title: "title #{id}",
          state: "todo",
          priority: nil,
          created_at: nil,
          blocked_by: []
        ],
        attrs
      )
    )
  end
end
