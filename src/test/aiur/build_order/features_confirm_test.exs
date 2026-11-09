defmodule Aiur.BuildOrder.FeaturesConfirmTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.Features

  @now ~U[2026-10-08 10:00:00Z]
  setup do
    dir = Aiur.TestSupport.tmp_root!("feature-confirm")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    clock = start_supervised!({Agent, fn -> @now end})
    pid = start_supervised!({Features, name: nil, state_dir: dir, clock: fn -> Agent.get(clock, & &1) end, general_epics: fn -> {:ok, []} end})
    meta = [server: pid, source: "cli:kevin", actor: "cli:kevin"]
    {:ok, _} = Features.create("a", %{label: "A", epics: [%{key: "f-a-ui", label: "UI"}, %{key: "f-a-api", label: "API"}]}, meta)
    {:ok, _} = Features.set_baseline("a", meta)
    {:ok, _} = Features.add("a", [12], Keyword.merge(meta, source: "backfill-agent", epic: "f-a-api", at_basis: :first_observed))
    %{meta: meta, dir: dir, clock: clock}
  end

  test "confirm preserves current epic, join provenance and baseline scope through replay", %{meta: meta, dir: dir, clock: clock} do
    assert {:ok, before} = Features.owner(12, meta)
    assert before.added? == true
    assert before.confirmed == false
    assert {:ok, journal} = Features.journal("a", meta)
    before_owner = Map.delete(before, :added?)
    Agent.update(clock, fn _ -> DateTime.add(@now, 60) end)

    assert {:ok, %{changed: [12], results: [%{id: 12, outcome: :confirmed, epic: "f-a-api", previous: ^before_owner}]}} =
             Features.confirm("a", [12, 12], meta)

    assert {:ok, owner} = Features.owner(12, meta)
    assert Map.take(owner, [:epic, :joined_at, :at_basis, :added?]) == Map.take(before, [:epic, :joined_at, :at_basis, :added?])
    assert owner.confirmed == true
    assert owner.source == "cli:kevin"
    assert owner.actor == "cli:kevin"
    assert {:ok, after_journal} = Features.journal("a", meta)
    assert length(after_journal) == length(journal) + 1
    assert List.last(after_journal).type == "member.added"
    assert List.last(after_journal).confirmed == true
    replay = start_supervised!({Features, name: nil, state_dir: dir, clock: fn -> DateTime.add(@now, 60) end, general_epics: fn -> {:ok, []} end}, id: :replay)
    assert {:ok, ^owner} = Features.owner(12, server: replay)
    assert {:ok, %{changed: [], results: [%{outcome: :unchanged}]}} = Features.confirm("a", [12, 12], meta)
    assert {:ok, ^after_journal} = Features.journal("a", meta)
  end

  test "a nonmember refuses the whole batch and bounded unknown inputs never write", %{meta: meta} do
    assert {:ok, before} = Features.snapshot(meta)
    assert {:ok, journal} = Features.journal("a", meta)
    assert {:error, {:not_member, [99]}} = Features.confirm("a", [12, 99], meta)
    assert {:error, {:unknown_feature, "nope"}} = Features.confirm("nope", [12], meta)
    assert {:error, :batch_too_large} = Features.confirm("a", Enum.to_list(1..1001), meta)
    assert {:error, :invalid_confirmation} = Features.confirm("a", [12], Keyword.put(meta, :source, "backfill-agent"))
    assert {:ok, ^before} = Features.snapshot(meta)
    assert {:ok, ^journal} = Features.journal("a", meta)
  end

  test "later same-feature backfill cannot change accepted epic or provenance", %{meta: meta} do
    assert {:ok, _} = Features.confirm("a", [12], meta)
    assert {:ok, owner} = Features.owner(12, meta)
    assert {:ok, %{changed: [], kept: [12]}} = Features.add("a", [12], Keyword.merge(meta, source: "backfill-agent", epic: "f-a-ui"))
    assert {:ok, ^owner} = Features.owner(12, meta)
  end
end
