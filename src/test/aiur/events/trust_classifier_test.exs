defmodule Aiur.Events.TrustClassifierTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.Sanitizer
  alias Aiur.GitHub.EventTrust

  defmodule FakeTrust do
    @behaviour Aiur.Events.TrustClassifier
    @impl true
    def trusted?(author), do: author == "alice"
  end

  defp put_classifier(mod) do
    prior = Application.fetch_env!(:aiur, Aiur.Events.TrustClassifier)
    Application.put_env(:aiur, Aiur.Events.TrustClassifier, mod)
    on_exit(fn -> Application.put_env(:aiur, Aiur.Events.TrustClassifier, prior) end)
  end

  test "stamp_author_trust uses the configured classifier" do
    put_classifier(FakeTrust)
    assert Sanitizer.stamp_author_trust(%{author: "alice"}).author_trusted? == true
    assert Sanitizer.stamp_author_trust(%{author: "bob"}).author_trusted? == false
  end

  test "default adapter never trusts an unlisted author" do
    assert EventTrust.trusted?("not-a-listed-author-zz9") == false
  end

  test "a broken classifier fails closed" do
    put_classifier(Aiur.Events.NoSuchClassifier)
    assert Sanitizer.stamp_author_trust(%{author: "alice"}).author_trusted? == false
  end

  test "sanitizer has no CodeOwners reference" do
    code =
      "lib/aiur/events/sanitizer.ex"
      |> File.read!()
      |> String.replace(~r/@(module)?doc """.*?"""/s, "")
      |> String.replace(~r/#.*$/m, "")

    refute code =~ "CodeOwners"
  end
end
