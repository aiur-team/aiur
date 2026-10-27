defmodule Aiur.Events.EnvelopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Events.Catalog
  alias Aiur.Events.Envelope
  alias Aiur.TicketObservation

  @envelope_keys ~w(v instance id topic class occurred_at observed_at source refs attrs payload_version anchor)
  @body "private comment body that must never be exported"
  @exported_entries Catalog.exported()

  test "drops every key not in the catalog allowlist" do
    assert {:ok, envelope} = Envelope.to_external({:event, event(%{body: @body, title: @body, message: @body, reason: @body, comment: %{"body" => @body}, files: [@body]})}, instance: "host/default")

    assert envelope["refs"] == %{"ticket" => "42", "pr_number" => 2210, "head_sha" => "abc1234"}
    assert envelope["attrs"] == %{}
    refute Jason.encode!(envelope) =~ @body
  end

  test "reads atom and string keys identically, preferring atom collisions" do
    atom_event = event()
    string_event = atom_event |> Jason.encode!() |> Jason.decode!()

    assert {:ok, atom_envelope} = Envelope.to_external(atom_event, instance: "host/default")
    assert {:ok, string_envelope} = Envelope.to_external(string_event, instance: "host/default")
    assert atom_envelope == string_envelope

    assert {:ok, %{"refs" => %{"pr_number" => 99}}} =
             Envelope.to_external(Map.put(string_event, :pr_number, 99), instance: "host/default")
  end

  test "unknown occurred_at stays null" do
    assert {:ok, %{"occurred_at" => nil}} = Envelope.to_external(event(%{ticket_observation: observation(occurred_at: nil)}), instance: "host/default")
  end

  test "invalid typed values become null" do
    invalid = event(%{head_sha: "not a sha", pr_number: -1, ticket_observation: observation(), ci_conclusion: "surprise"}, "ticket.42.ci.passed")

    assert {:ok, envelope} = Envelope.to_external(invalid, instance: "host/default")
    assert envelope["refs"] == %{"ticket" => "42", "pr_number" => nil, "head_sha" => nil}
    assert envelope["attrs"] == %{"ci_conclusion" => nil}
  end

  test "non-exported topics and malformed ids are skipped" do
    assert :skip = Envelope.to_external(event(%{}, "executor.decision.requested"), instance: "host/default")
    assert :skip = Envelope.to_external(event(%{}, "ticket.1.agent.custom.x"), instance: "host/default")
    assert :skip = Envelope.to_external(event(%{id: 0}), instance: "host/default")
  end

  test "anchor is null and source derives only from the observation" do
    assert {:ok, %{"anchor" => nil, "source" => "legacy"}} = Envelope.to_external(event(), instance: "host/default")

    assert {:ok, %{"source" => "agent"}} =
             Envelope.to_external(event(%{ticket_observation: observation(source: %{kind: :agent_event})}), instance: "host/default")

    assert {:ok, %{"source" => "alert"}} =
             Envelope.to_external(event(%{source: "alert"}), instance: "host/default")

    assert {:ok, %{"source" => "unknown"}} =
             Envelope.to_external(Map.delete(event(), :ticket_observation), instance: "host/default")
  end

  test "serializes every exported catalog entry's references and attrs" do
    for entry <- @exported_entries do
      topic = topic_for(entry.pattern)

      assert {:ok, envelope} =
               Envelope.to_external(event(Map.merge(ref_values(entry.refs), attr_values(entry.attrs)), topic),
                 instance: "host/default",
                 catalog: fn ^topic -> entry end
               )

      assert envelope["refs"] == expected_refs(entry.refs, topic)
      assert envelope["attrs"] == expected_attrs(entry.attrs)
    end
  end

  test "validates bounded identifier-list refs and attrs" do
    topic = "ticket.42.queue.attention.prerequisite_failed"
    catalog = fn ^topic -> Catalog.lookup(topic) end

    assert {:ok, %{"refs" => %{"blocked" => ["ticket-7"]}, "attrs" => %{"blocked" => ["ticket-7"]}}} =
             Envelope.to_external(event(%{blocked: ["ticket-7"]}, topic), instance: "host/default", catalog: catalog)

    for blocked <- [["ticket-7", "not an identifier"], List.duplicate("ticket-7", 101)] do
      assert {:ok, %{"refs" => %{"blocked" => nil}, "attrs" => %{"blocked" => nil}}} =
               Envelope.to_external(event(%{blocked: blocked}, topic), instance: "host/default", catalog: catalog)
    end
  end

  @tag timeout: 180_000
  property "every exported event has only its catalog-defined fields" do
    check all(
            payload <- map_of(string(:alphanumeric), one_of([integer(), boolean(), string(:alphanumeric)]), max_length: 24),
            max_runs: 1_000
          ) do
      for entry <- @exported_entries do
        topic = topic_for(entry.pattern)
        event = Map.merge(%{id: 1, topic: topic, ticket_observation: observation()}, payload)

        assert {:ok, envelope} =
                 Envelope.to_external(event,
                   instance: "host/default",
                   catalog: fn ^topic -> entry end
                 )

        assert Enum.sort(Map.keys(envelope)) == Enum.sort(@envelope_keys)
        refute Map.has_key?(envelope, "seq")
        assert MapSet.subset?(MapSet.new(Map.keys(envelope["refs"])), MapSet.new(Enum.map(entry.refs, &Atom.to_string/1)))
        assert MapSet.subset?(MapSet.new(Map.keys(envelope["attrs"])), MapSet.new(Enum.map(entry.attrs, &(elem(&1, 0) |> Atom.to_string()))))
      end
    end
  end

  defp event(overrides \\ %{}, topic \\ "ticket.42.pr.merged") do
    Map.merge(%{id: 1_791_281_110_183_123, topic: topic, pr_number: 2210, head_sha: "abc1234", ticket_observation: observation()}, overrides)
  end

  defp observation(overrides \\ []) do
    struct(TicketObservation, Keyword.merge([source: %{kind: :legacy}, occurred_at: nil, observed_at: ~U[2026-10-06 15:02:13Z]], overrides))
  end

  defp topic_for("ticket.*.agent.decision.#"), do: "ticket.42.agent.decision.answered"
  defp topic_for("ticket.*.agent.attention.#"), do: "ticket.42.agent.attention.example"
  defp topic_for("system.#"), do: "system.dispatch.cycle_stalled"
  defp topic_for(pattern), do: pattern |> String.replace("*", "42") |> String.replace("#", "example")

  defp ref_values(refs) do
    refs
    |> Enum.reject(&(&1 == :ticket))
    |> Map.new(&{&1, ref_value(&1)})
  end

  defp expected_refs(refs, topic), do: Map.new(refs, &{Atom.to_string(&1), ref_value(&1, topic)})

  defp ref_value(:ticket, "ticket." <> rest), do: rest |> String.split(".", parts: 2) |> List.first()
  defp ref_value(:ticket, _topic), do: nil
  defp ref_value(ref, _topic), do: ref_value(ref)

  defp ref_value(:pr_number), do: 2210
  defp ref_value(:job_id), do: "run-42-1"
  defp ref_value(:head_sha), do: "abc1234"
  defp ref_value(:decision_id), do: "decision-1"
  defp ref_value(:decision_version), do: 1
  defp ref_value(:queue_id), do: "queue-1"
  defp ref_value(:prerequisite), do: "ticket-7"
  defp ref_value(:blocked), do: ["ticket-7"]
  defp ref_value(:root), do: "root-1"

  defp attr_values(attrs), do: Map.new(attrs, &{elem(&1, 0), attr_value(elem(&1, 1))})
  defp expected_attrs(attrs), do: Map.new(attrs, &{elem(&1, 0) |> Atom.to_string(), attr_value(elem(&1, 1))})

  defp attr_value({:enum, [value | _values]}), do: value
  defp attr_value({:list, :id}), do: ["ticket-7"]
  defp attr_value(:integer), do: 1
  defp attr_value(:boolean), do: true
  defp attr_value(:id), do: "identifier-1"
  defp attr_value(:sha), do: "abc1234"
end
