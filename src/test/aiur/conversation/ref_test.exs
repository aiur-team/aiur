defmodule Aiur.Conversation.RefTest do
  use ExUnit.Case, async: true
  alias Aiur.Conversation.Ref
  alias Aiur.TrackerIdentity

  test "repository identity ignores case and display identifier" do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_abc", "number" => 6621}, {"Owner", "Repo"}, {"Owner", "Repo"})
    {:ok, ref} = Ref.worker(identity)
    {:ok, same} = Ref.worker(%{identity | owner: "owner", repository: "repo", identifier: "99"})
    assert Ref.conversation_id(ref) == Ref.conversation_id(same)
    assert Ref.canonical(ref) == "worker:github:owner/repo:I_abc"
    expected = "conv_" <> String.slice(Base.encode32(:crypto.hash(:sha256, "worker:github:owner/repo:I_abc"), case: :lower, padding: false), 0, 26)
    assert Ref.conversation_id(ref) == expected
    {:ok, other} = Ref.worker(%{identity | provider_id: "I_other"})
    refute Ref.conversation_id(ref) == Ref.conversation_id(other)
  end

  test "unjoinable identities are rejected" do
    assert Ref.worker(TrackerIdentity.unjoinable(:legacy)) == {:error, :unjoinable}
    assert Ref.worker(%{}) == {:error, :unjoinable}
  end

  test "Executor has a stable canonical identity" do
    assert Ref.canonical(Ref.executor()) == "executor"
    assert Ref.conversation_id(Ref.executor()) == "conv_" <> String.slice(Base.encode32(:crypto.hash(:sha256, "executor"), case: :lower, padding: false), 0, 26)
  end
end
