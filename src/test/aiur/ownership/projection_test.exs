defmodule Aiur.Ownership.ProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Labels
  alias Aiur.Ownership
  alias Aiur.Ownership.Projection

  @self %{gateway_id: "PC" <> String.duplicate("A", 24), gateway_label: "PC", daemon_key: "aiur-u"}
  @pc %{gateway_id: @self.gateway_id, gateway_label: "PC", daemon_key: "aiur-u", state: "owned"}
  @nook %{gateway_id: "NK" <> String.duplicate("B", 24), gateway_label: "Nook", daemon_key: "aiur-k", state: "owned"}

  defp reconcile(ref, labels), do: Projection.reconcile(ref, %{labels: labels, self: @self})

  test "ref says PC, no label: project gateway:pc" do
    assert reconcile({:owned, @pc}, ["agent:todo"]) == {:project, "pc"}
    assert reconcile({:owned, @pc}, ["Gateway:PC"]) == :consistent
  end

  test "ref and label disagree, or ref unreadable: ambiguous" do
    assert reconcile({:owned, @nook}, ["gateway:pc"]) == {:ambiguous, :label_disagrees}
    assert reconcile({:owned, @pc}, ["gateway:nook"]) == {:ambiguous, :label_disagrees}
    assert reconcile({:owned, @pc}, ["gateway:pc", "gateway:nook"]) == {:ambiguous, :label_disagrees}
    assert reconcile({:unreadable, :timeout}, []) == {:ambiguous, :ref_unreadable}
  end

  test "foreign owner with matching or no label is skipped quietly" do
    assert reconcile({:owned, @nook}, ["gateway:nook"]) == :foreign
    assert reconcile({:owned, @nook}, []) == :foreign
    assert reconcile({:owned, %{@pc | daemon_key: "aiur-u-test"}}, ["gateway:pc"]) == :foreign
  end

  test "label without ref" do
    assert reconcile(:unowned, ["gateway:pc"]) == {:assignment_request, ["pc"]}
    assert reconcile(:unowned, ["gateway:nook", "agent:todo"]) == {:hint_other, "nook"}
    assert reconcile(:unowned, ["gateway:pc", "agent:todo"]) == :unlabelled
    assert reconcile(:unowned, ["agent:todo"]) == :unlabelled
  end

  test "slug" do
    assert Projection.slug("Nook (Home)", "x") == "nook-home"
    assert Projection.slug("###", "01HZXABCDEFG") == "01hzxabc"
    long = Projection.slug(String.duplicate("ab ", 20), "x")
    assert String.length(long) <= 42 and not String.ends_with?(long, "-")
  end

  test "describe and label spec" do
    assert Labels.describe("gateway:nook") =~ "mirrors the ownership ref"
    assert %{color: "1d76db"} = Labels.gateway_label("nook")
  end

  test "ensure_with posts colour and description" do
    parent = self()
    fun = fn req -> send(parent, {:req, req.body}) && {:ok, %{status: 201, body: %{}}} end
    assert :ok = Labels.ensure_with("o", "r", "t", [Labels.gateway_label("pc")], request_fun: fun)
    assert_receive {:req, %{"name" => "gateway:pc", "color" => "1d76db", "description" => "Owned by gateway pc" <> _}}
  end

  describe "Ownership.ensure_owned wiring" do
    defp issue(labels) do
      struct!(Aiur.Issue,
        id: "12",
        identifier: "12",
        labels: labels,
        tracker_identity: %Aiur.TrackerIdentity{status: :joinable, kind: :github, owner: "o", repository: "r", provider_id: "n", identifier: "12"}
      )
    end

    defp opts(read, claim) do
      parent = self()

      [
        ownership_enabled: true,
        ownership_self: @self,
        ownership_read_fun: fn _, _, _ -> read end,
        ownership_claim_fun: fn _, _, _, _ -> claim end,
        ownership_label_fun: fn _issue, slug -> send(parent, {:label, slug}) end,
        ownership_alert_fun: fn issue, reason -> send(parent, {:alert, issue.identifier, reason}) end
      ]
    end

    test "won claim adds the label" do
      assert {:ok, _} = Ownership.ensure_owned(issue(["agent:todo"]), opts({:ok, %{record: nil}}, {:won, @pc}))
      assert_received {:label, "pc"}
    end

    test "consistent label is not re-added" do
      assert {:ok, _} = Ownership.ensure_owned(issue(["gateway:pc"]), opts({:ok, %{record: @pc}}, nil))
      refute_received {:label, _}
    end

    test "ref nook, label pc: declined and alerted, no claim attempted" do
      o = opts({:ok, %{record: @nook}}, nil)
      assert {:declined, :ambiguous, :label_disagrees} = Ownership.ensure_owned(issue(["gateway:pc"]), o)
      assert_received {:alert, "12", :label_disagrees}
    end

    test "label with no ref and no state label is not dispatched" do
      assert {:declined, :not_owner, {:assignment_request, ["pc"]}} =
               Ownership.ensure_owned(issue(["gateway:pc"]), opts({:ok, %{record: nil}}, {:won, @pc}))
    end
  end
end
