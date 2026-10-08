defmodule Aiur.BuildQueue.ModelTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Aiur.BuildQueue.Model
  alias Aiur.BuildQueue.Model.{Edge, Intent, Item, Latch, Observation, Queue}

  property "round-trips a document through JSON" do
    check all(
            issue <- integer(1..100_000),
            position <- integer(0..100),
            source <- member_of([:list, :build_order, :native]),
            action <- member_of([:promote, :withdraw, :mark, :unmark]),
            hold <- member_of([nil, :operator, :external]),
            override <- member_of([nil, :manual_promotion]),
            outcome <- member_of([nil, :ok, {:error, {:denied, %{status: 403}}}]),
            count <- integer(2..4)
          ) do
      document = document()
      item = %{hd(document.items) | issue_id: to_string(issue), position: position, hold: hold, override: override}
      edge = %{hd(document.edges) | source: source}
      intent = %{hd(document.intents) | action: action, outcome: outcome}

      document = %{
        document
        | items: Enum.map(1..count, &%{item | issue_id: to_string(issue + &1), position: position + &1}),
          edges: Enum.map(1..count, &%{edge | dependent: to_string(issue + &1)}),
          intents: Enum.map(1..count, &%{intent | id: "intent-#{&1}"})
      }

      assert {:ok, ^document} = document |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
    end
  end

  test "rejects version 2 and every other version" do
    for version <- [2, 0, nil, "1", %{}, []] do
      assert Model.decode(Map.put(encoded(), "version", version)) == {:error, {:unsupported_version, version}}
    end

    assert Model.decode(%{}) == {:error, {:invalid, ["version"]}}
    assert Model.decode(nil) == {:error, {:invalid, []}}
  end

  test "rejects an unknown action atom without interning input" do
    unknown = "queue_unknown_action_#{System.unique_integer([:positive])}"
    assert Model.decode(put_in(encoded(), ["intents", Access.at(0), "action"], unknown)) == {:error, {:invalid, ["intents", 0, "action"]}}
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "does not persist observations or titles and ignores extra keys" do
    document = document()
    observation = %Observation{issue_id: "12", open?: :unknown, labels: [], state_reason: nil, pr: nil, observed_at_ms: 0}
    extended = Map.merge(document, %{observations: [observation], titles: ["secret"], bodies: ["private"]})
    extended = put_in(extended, [:queues, Access.at(0)], Map.put(hd(document.queues), :title, "secret"))
    encoded = Model.encode(extended)
    assert encoded == Model.encode(document)
    assert Enum.sort(Map.keys(encoded)) == ~w(edges intents items latches queues version)
    refute String.contains?(Jason.encode!(encoded), "secret")
    assert {:ok, ^document} = Model.decode(Map.put(encoded, "future", true))
    assert {:ok, ^document} = Model.decode(put_in(encoded, ["queues", Access.at(0), "future"], true))
  end

  test "rejects missing and corrupt fields with their exact paths" do
    invalid = [
      {"queues", "id", ["q-nope", "q-12345", 1]},
      {"queues", "name", [nil, "", 5]},
      {"queues", "kind", ["other", :list, nil]},
      {"queues", "root", [0, -1, "12"]},
      {"queues", "held", [nil, "false", 0]},
      {"queues", "generation", [-1, 1.0, nil]},
      {"queues", "created_at", [nil, "yesterday", 0]},
      {"items", "issue_id", ["0", "-1", "x", 12]},
      {"items", "queue_id", [nil, "q-foo"]},
      {"items", "position", [-1, "0", 1.5]},
      {"items", "hold", ["other", false]},
      {"items", "override", ["other", false]},
      {"items", "promoted_at", ["bad", 0]},
      {"items", "added_at", [nil, "bad"]},
      {"edges", "prerequisite", [nil, "abc"]},
      {"edges", "dependent", ["0", 4]},
      {"edges", "source", ["other", nil]},
      {"intents", "id", [nil, ""]},
      {"intents", "issue_id", [nil, "abc"]},
      {"intents", "target_labels", [nil, "todo", [1], [""]]},
      {"intents", "recorded_at_ms", [-1, nil, "0"]},
      {"intents", "outcome", ["error", false, %{"error" => "invalid"}, %{"error" => Base.encode64(<<0>>)}]},
      {"latches", "key", [nil, "invalid", Base.encode64(:erlang.term_to_binary(:not_a_pair))]},
      {"latches", "opened_at_ms", [nil, -1]}
    ]

    for {collection, field, values} <- invalid do
      path = [collection, 0, field]
      for value <- values, do: assert(Model.decode(put_in(encoded(), [collection, Access.at(0), field], value)) == {:error, {:invalid, path}})
      missing = update_in(encoded(), [collection, Access.at(0)], &Map.delete(&1, field))
      assert Model.decode(missing) == {:error, {:invalid, path}}
    end
  end

  test "rejects corrupt collections and records without raising" do
    for collection <- ~w(queues items edges intents latches) do
      for value <- [nil, %{}, "bad", 1] do
        assert Model.decode(Map.put(encoded(), collection, value)) == {:error, {:invalid, [collection]}}
      end

      assert Model.decode(Map.delete(encoded(), collection)) == {:error, {:invalid, [collection]}}
      assert Model.decode(Map.put(encoded(), collection, [nil])) == {:error, {:invalid, [collection, 0]}}
    end
  end

  test "round-trips nullable timestamps, build-order positions and empty documents" do
    document = document()
    queue = %{hd(document.queues) | kind: :build_order, root: 12}
    item = %{hd(document.items) | position: nil, promoted_at: nil}
    document = %{document | queues: [queue], items: [item]}
    assert {:ok, ^document} = document |> Model.encode() |> Jason.encode!() |> Jason.decode!() |> Model.decode()
    empty = %{queues: [], items: [], edges: [], intents: [], latches: []}
    assert {:ok, ^empty} = empty |> Model.encode() |> Model.decode()
  end

  test "rejects positions inconsistent with queue kind" do
    assert Model.decode(put_in(encoded(), ["items", Access.at(0), "position"], nil)) == {:error, {:invalid, ["items", 0, "position"]}}
    assert Model.decode(put_in(encoded(), ["queues", Access.at(0), "kind"], "build_order")) == {:error, {:invalid, ["items", 0, "position"]}}
    assert Model.decode(put_in(encoded(), ["items", Access.at(0), "queue_id"], "q-ffff")) == {:error, {:invalid, ["items", 0, "queue_id"]}}
  end

  test "rejects opaque terms containing new atoms or trailing bytes" do
    unknown = "queue_unknown_reason_#{System.unique_integer([:positive])}"
    atom_payload = Base.encode64(<<131, 119, byte_size(unknown), unknown::binary>>)
    trailing_payload = Base.encode64(:erlang.term_to_binary(:denied) <> <<0>>)

    for payload <- [atom_payload, trailing_payload] do
      corrupt = put_in(encoded(), ["intents", Access.at(0), "outcome"], %{"error" => payload})
      assert Model.decode(corrupt) == {:error, {:invalid, ["intents", 0, "outcome"]}}
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "rejects improper lists without raising" do
    for collection <- ~w(queues items edges intents latches) do
      assert Model.decode(Map.put(encoded(), collection, [%{} | :bad])) == {:error, {:invalid, [collection]}}
    end

    bad_labels = put_in(encoded(), ["intents", Access.at(0), "target_labels"], ["agent:todo" | :bad])
    assert Model.decode(bad_labels) == {:error, {:invalid, ["intents", 0, "target_labels"]}}
  end

  defp encoded, do: Model.encode(document())

  defp document do
    time = ~U[2026-10-07 12:34:56.123456Z]

    %{
      queues: [%Queue{id: "q-ab12", name: "Release", kind: :list, root: nil, held: false, generation: 0, created_at: time}],
      items: [%Item{issue_id: "12", queue_id: "q-ab12", position: 0, hold: nil, override: nil, promoted_at: time, added_at: time}],
      edges: [%Edge{prerequisite: "12", dependent: "13", source: :list}],
      intents: [%Intent{id: "intent-1", issue_id: "12", action: :promote, target_labels: ["agent:todo"], recorded_at_ms: 123, outcome: nil}],
      latches: [%Latch{key: {:prerequisite_failed, "12"}, opened_at_ms: 123}]
    }
  end
end
