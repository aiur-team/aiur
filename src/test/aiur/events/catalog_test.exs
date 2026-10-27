defmodule Aiur.Events.CatalogTest do
  use ExUnit.Case, async: true

  alias Aiur.Events
  alias Aiur.Events.Catalog
  alias Aiur.Events.Catalog.Entry

  @legacy %{
    "decision_store.unrecognized_event_types" => "commands",
    "decision_store.corrupted" => "commands",
    "decision_store.repair_failed" => "commands",
    "decision_store.append_ambiguous" => "commands",
    "executor_events.corrupted" => "executor-attention",
    "github.dispatch_authorization.ambiguous" => "github",
    "github.dispatch_authorization.timeline_unreadable" => "github",
    "orchestrator.claim_released" => "orchestration"
  }

  test "lookup picks the most specific entry and unknown topics use the private live default" do
    assert %Entry{pattern: "ticket.*.agent.decision.#", class: :journaled, export?: true} = Catalog.lookup("ticket.42.agent.decision.answered")
    assert %Entry{pattern: "ticket.*.agent.#", class: :logged, export?: false} = Catalog.lookup("ticket.42.agent.phase.work.start")
    assert %Entry{pattern: "#", class: :live, export?: false, refs: [], attrs: [], owner: "unknown"} = Catalog.default()
    assert Catalog.lookup("foo.bar") == Catalog.default()
    assert Catalog.lookup("ticket.42.future.new") == Catalog.default()
    assert %Entry{class: :live, export?: false} = Catalog.lookup("system.main.branch.push")
  end

  test "exported entries declare refs or attrs and only typed attrs" do
    exported = Catalog.exported()
    assert Enum.any?(exported, &(&1.pattern == "ticket.*.ci.passed"))
    assert exported == Enum.filter(Catalog.entries(), & &1.export?)

    for entry <- exported do
      assert entry.refs != [] or entry.attrs != [], entry.pattern
      assert Enum.all?(entry.refs, &(&1 in [:ticket, :pr_number, :head_sha, :decision_id, :decision_version, :queue_id, :prerequisite, :blocked, :root])), entry.pattern
      assert Enum.all?(entry.attrs, fn {key, type} -> is_atom(key) and allowed_type?(type) end), entry.pattern
      assert approved_export?(entry.pattern), "Unapproved export: #{entry.pattern}"
    end
  end

  test "approved export families retain exact identifier and enum allowlists" do
    decision = Catalog.lookup("ticket.42.agent.decision.answered")
    assert decision.refs == [:ticket, :decision_id, :decision_version]
    assert [slug: {:enum, slugs}] = decision.attrs
    requests = File.read!(Path.expand("../../../lib/aiur/decision_store/requests.ex", __DIR__))
    producer_slugs = Regex.scan(~r/def lifecycle_slug\([^)]*\), do: "([^"]+)"/, requests) |> Enum.map(&List.last/1)
    assert producer_slugs != []
    assert Enum.sort(slugs) == Enum.sort(["requested" | producer_slugs])

    for verb <- ~w(opened ready_for_review merged), do: assert_pr_refs("ticket.42.pr.#{verb}", [])

    for verb <- ~w(passed failed) do
      assert_pr_refs("ticket.42.ci.#{verb}", ci_conclusion: {:enum, ~w(success failure cancelled timed_out action_required neutral skipped stale)})
    end

    for suffix <- ~w(issue.commented pr.review_comment) do
      assert %Entry{export?: true, refs: [:ticket, :pr_number], attrs: [author_trusted?: :boolean]} = Catalog.lookup("ticket.42.#{suffix}")
    end

    for suffix <- ~w(progress progress.checkin) do
      assert %Entry{export?: true, refs: [], attrs: [percent: :integer]} = Catalog.lookup("ticket.42.agent.#{suffix}")
    end

    assert %Entry{
             class: :journaled,
             export?: true,
             refs: [:ticket, :decision_id, :decision_version],
             attrs: [requester_kind: {:enum, ~w(worker executor)}, blocking: :boolean, urgency: {:enum, ~w(low normal high critical)}, cause: {:enum, _}]
           } =
             Catalog.lookup("ticket.42.agent.decision.human-needed")

    assert %Entry{class: :live, export?: true, refs: [:ticket, :pr_number]} = Catalog.lookup("ticket.42.pr.closed_unmerged")
    assert %Entry{class: :live, export?: true, refs: [:ticket, :pr_number], reserved: true} = Catalog.lookup("ticket.42.issue.closed")

    assert %Entry{class: :live, export?: true, refs: [:ticket, :queue_id], attrs: [cause: {:enum, _}]} =
             Catalog.lookup("ticket.42.queue.promoted")

    assert %Entry{pattern: "ticket.*.queue.#", class: :live, export?: true, refs: [:ticket, :queue_id]} =
             Catalog.lookup("ticket.42.queue.future")

    assert %Entry{class: :ledgered, export?: true, refs: [:ticket, :prerequisite, :blocked], attrs: [cause: {:enum, _}, blocked: {:list, :id}]} =
             Catalog.lookup("ticket.42.queue.attention.prerequisite_failed")

    for topic <- ["system.queue.q1.progress", "system.build_order.root.progress"] do
      assert %Entry{class: :ledgered, export?: true, attrs: [milestone: {:enum, ~w(25 50 75 100)}, percent: :integer, generation: :integer, freshness: {:enum, _}]} = Catalog.lookup(topic)
    end

    assert %Entry{class: :live, export?: true, attrs: [requested: {:enum, ~w(steer sync async)}, effective: {:enum, ~w(steer sync async)}, effective_reason: {:enum, _}, version: :integer]} =
             Catalog.lookup("ticket.42.agent.listen-mode.changed")

    assert %Entry{class: :live, export?: true, attrs: [revision: :integer]} = Catalog.lookup("system.capabilities.changed")

    for topic <- ["ticket.42.agent.attention.example", "system.dispatch.cycle_stalled"] do
      assert %Entry{class: :ledgered, export?: true, refs: [:ticket], attrs: [severity: {:enum, ~w(info warning error)}, needs_attention: :boolean]} = Catalog.lookup(topic)
    end
  end

  test "planned topic registrations name their component owners and reserve unproduced entries" do
    assert %Entry{owner: "commands", reserved: false} = Catalog.lookup("ticket.42.agent.decision.human-needed")
    assert %Entry{owner: "github-listeners", reserved: true} = Catalog.lookup("ticket.42.issue.closed")
    assert %Entry{owner: "build-queue"} = Catalog.lookup("ticket.42.queue.attention.prerequisite_failed")
    assert %Entry{owner: "build-orders"} = Catalog.lookup("system.build_order.root.progress")
    assert %Entry{owner: "orchestration", reserved: true} = Catalog.lookup("ticket.42.agent.listen-mode.changed")
    assert %Entry{owner: "identity"} = Catalog.lookup("system.capabilities.changed")
    assert %Entry{owner: "conversations", reserved: true, export?: false} = Catalog.lookup("executor.conversation.appended")
  end

  test "human-needed exports no text fields" do
    entry = Catalog.lookup("ticket.42.agent.decision.human-needed")
    refute :short_label in entry.refs
    refute :question in entry.refs
    refute Keyword.has_key?(entry.attrs, :short_label)
    refute Keyword.has_key?(entry.attrs, :question)
  end

  test "no two catalog entries tie on specificity for an overlapping topic" do
    entries = Catalog.entries()
    assert length(entries) == MapSet.size(MapSet.new(entries, & &1.pattern))

    for left <- entries, right <- entries, left.pattern < right.pattern, Events.specificity_score(left.pattern) == Events.specificity_score(right.pattern) do
      refute overlapping?(left.pattern, right.pattern), "Ambiguous catalog patterns: #{left.pattern} and #{right.pattern}"
    end
  end

  test "executor and custom agent topics are never exported" do
    for topic <- ~w(executor.decision.requested executor.decision.answered executor.command.operator_relayed executor.unknown.x ticket.1.agent.custom.x ticket.1.agent.custom.x.y) do
      refute Catalog.lookup(topic).export?, topic
    end

    assert %Entry{pattern: "executor.#", class: :journaled} = Catalog.lookup("executor.decision.requested")
    assert %Entry{pattern: "ticket.*.agent.custom.#", class: :logged} = Catalog.lookup("ticket.1.agent.custom.x")
  end

  test "out-of-grammar alert topics are explicitly ledgered and private" do
    for {topic, owner} <- @legacy do
      assert %Entry{pattern: ^topic, class: :ledgered, export?: false, owner: ^owner} = Catalog.lookup(topic)
    end
  end

  test "entries have owners, valid durability classes and initial payload versions" do
    component_ids =
      Path.expand("../../../../components/*.json", __DIR__)
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() |> Map.fetch!("id") end)
      |> MapSet.new()

    assert MapSet.member?(component_ids, "harness-adapters")

    for entry <- Catalog.entries() do
      assert MapSet.member?(component_ids, entry.owner), "Unknown owner #{inspect(entry.owner)}: #{entry.pattern}"
      assert entry.class in [:ephemeral, :live, :ledgered, :logged, :journaled], entry.pattern
      assert entry.payload_version == 1, entry.pattern
    end
  end

  test "alert export requires explicit approval at its call site" do
    assert %Entry{class: :ledgered, export?: false} = Entry.alert("unapproved.alert", "harness-adapters")
    assert %Entry{export?: false} = Entry.alert("system.future.alert", "signal", export?: false)
    assert %Entry{export?: true, refs: [:ticket], attrs: [severity: {:enum, ~w(info warning error)}, needs_attention: :boolean]} = Entry.alert("system.approved.alert", "signal", export?: true)
  end

  test "computed alert resolutions remain ledgered rather than falling back to live or logged" do
    for suffix <- ~w(agent.paused merge.attribution_check_failed pr.human_review_without_pr pr.parked_ready pr.tested_head_stale) do
      topic = "ticket.42.#{suffix}.resolved"
      assert %Entry{class: :ledgered, export?: false, owner: "orchestration"} = Catalog.lookup(topic)
    end
  end

  defp assert_pr_refs(topic, attrs) do
    assert %Entry{export?: true, refs: [:ticket, :pr_number, :head_sha], attrs: ^attrs} = Catalog.lookup(topic)
  end

  defp allowed_type?({:enum, values}), do: is_list(values) and values != [] and Enum.all?(values, &is_binary/1)
  defp allowed_type?({:list, :id}), do: true
  defp allowed_type?(type), do: type in [:integer, :boolean, :id, :sha]

  defp approved_export?("executor.decision.human-needed"), do: true

  defp approved_export?(pattern) do
    Enum.any?(
      ~w(ticket.*.agent.decision.# ticket.*.pr.opened ticket.*.pr.ready_for_review ticket.*.pr.merged ticket.*.pr.closed_unmerged ticket.*.issue.closed
      ticket.*.ci.passed ticket.*.ci.failed ticket.*.issue.commented ticket.*.pr.review_comment ticket.*.agent.progress ticket.*.agent.progress.checkin
      ticket.*.agent.attention.# ticket.*.queue.# ticket.*.queue.promoted ticket.*.queue.withdrawn ticket.*.queue.held ticket.*.queue.released ticket.*.queue.overridden
      ticket.*.queue.removed ticket.*.queue.attention.# system.queue.*.progress system.queue.attention.# system.build_order.*.progress
      ticket.*.agent.listen-mode.changed system.capabilities.changed system.#),
      &Events.matches?(&1, pattern)
    )
  end

  defp overlapping?("#" <> _, _right), do: true
  defp overlapping?(_left, "#" <> _), do: true
  defp overlapping?(left, right), do: overlap_segments?(String.split(left, "."), String.split(right, "."))
  defp overlap_segments?(["#" | _], _right), do: true
  defp overlap_segments?(_left, ["#" | _]), do: true
  defp overlap_segments?([], []), do: true
  defp overlap_segments?([left | rest_left], [right | rest_right]) when left == right or left == "*" or right == "*", do: overlap_segments?(rest_left, rest_right)
  defp overlap_segments?(_left, _right), do: false
end
