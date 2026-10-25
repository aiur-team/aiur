defmodule Aiur.BuildOrder.BackfillGuardsTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.{Epic, EpicOverrides, Features}
  @general [%{key: "bugs", label: "Bugs", labels: ["bug"], hue: 38}, %{key: "design", label: "Design", labels: ["design"], hue: 312}]
  @guess %{actor: "agent:2901", source: "backfill-agent"}

  setup do
    dir = Aiur.TestSupport.tmp_root!("backfill-guards")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    start_supervised!({EpicOverrides, name: name, state_dir: Path.join(dir, "epics"), repository: "acme/app", settings_fun: fn -> {:ok, %{build_order: %{general_epics: @general}}} end})
    features = start_supervised!({Features, name: nil, state_dir: Path.join(dir, "features"), general_epics: fn -> {:ok, @general} end})
    %{epics: [server: name], features: [server: features, actor: "cli:kevin", source: "cli:kevin"]}
  end

  test "backfill preserves settled epic overrides without journaling", c do
    for source <- ["cli:kevin", "agent:42"] do
      human = %{actor: source, source: source}
      assert {:ok, _} = EpicOverrides.set("bugs", [12], human, c.epics)
      assert {:ok, before} = EpicOverrides.journal([12], c.epics)
      assert {:ok, %{results: [%{status: :kept_existing, previous: %{epic: "bugs", source: ^source}}]}} = EpicOverrides.set("design", [12], @guess, c.epics)
      assert {:ok, %{12 => %{epic: "bugs", confirmed: true}}, _} = EpicOverrides.all(c.epics)
      assert {:ok, ^before} = EpicOverrides.journal([12], c.epics)
    end
  end

  # Future regression guard: predecessor already permits replacing a guess.
  test "a later backfill guess replaces a previous guess", c do
    assert {:ok, _} = EpicOverrides.set("bugs", [12], @guess, c.epics)
    assert {:ok, %{results: [%{status: :changed}]}} = EpicOverrides.set("design", [12], @guess, c.epics)
    assert {:ok, %{12 => %{epic: "design", confirmed: false}}, _} = EpicOverrides.all(c.epics)
  end

  test "backfill skips another feature's member but adds unowned rows", c do
    create_features(c.features)
    assert {:ok, _} = Features.add("a", [12], c.features)
    assert {:ok, before} = Features.journal("a", c.features)
    assert {:ok, %{kept: [12], changed: [13]}} = Features.add("b", [12, 13], guess(c.features))
    assert {:ok, %{feature: "a", confirmed: true}} = Features.owner(12, c.features)
    assert {:ok, %{feature: "b", confirmed: false}} = Features.owner(13, c.features)
    assert {:ok, ^before} = Features.journal("a", c.features)
    assert {:ok, %{kept: [12], changed: []}} = Features.add("b", [12], guess(c.features))
  end

  test "backfill cannot move even an unconfirmed member", c do
    create_features(c.features)
    assert {:ok, _} = Features.add("a", [12], guess(c.features))
    assert {:ok, before} = Features.snapshot(c.features)
    assert {:error, :backfill_cannot_move} = Features.add("b", [12], Keyword.put(guess(c.features), :move, true))
    assert {:ok, ^before} = Features.snapshot(c.features)
    assert {:ok, %{feature: "a", confirmed: false}} = Features.owner(12, c.features)
  end

  test "an unconfirmed override yields to a matching label" do
    context = %{general: @general, features: %{}}
    ticket = %{labels: ["bug"], override: %{epic: "design", actor: "agent:2901", confirmed: false}}
    assert %{key: "bugs", source: "label:bug", ignored: [:override_unconfirmed_below_label]} = Epic.resolve(ticket, context)
    assert %{key: "design", source: "override:agent:2901", gaps: []} = Epic.resolve(%{ticket | labels: []}, context)
    assert %{key: "design", source: "override:agent:2901"} = Epic.resolve(%{ticket | override: Map.put(ticket.override, :confirmed, true)}, context)
    assert %{key: "design", source: "override:agent:2901"} = Epic.resolve(%{ticket | override: Map.delete(ticket.override, :confirmed)}, context)
    assert %{key: "design", gaps: []} = Epic.resolve(%{ticket | labels: :unknown}, context)
  end

  defp guess(opts), do: Keyword.merge(opts, Map.to_list(@guess))

  defp create_features(opts) do
    for slug <- ["a", "b"], do: assert({:ok, _} = Features.create(slug, %{label: String.upcase(slug)}, opts))
  end
end
