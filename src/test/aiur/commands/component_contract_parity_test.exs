defmodule Aiur.Commands.ComponentContractParityTest do
  @moduledoc """
  Parity guard between the three surfaces that render a Command.

  The shared fixture file is read by this test (the Elixir contract and the
  dashboard card) *and* by `packages/aiur-commands/test/render.test.mjs` (the
  embeddable renderer). A change to what a Command state means on one surface
  fails the other, which is what stops the dashboard and an embedded host from
  drifting apart.
  """

  use ExUnit.Case, async: true

  alias Aiur.Commands.ComponentState
  alias AiurWeb.Conversation.CommandCards

  @fixture_path Path.expand(
                  "../../../../packages/aiur-commands/test/fixtures/command-states.json",
                  __DIR__
                )

  setup_all do
    assert File.exists?(@fixture_path), "shared Command component fixtures are missing at #{@fixture_path}"

    %{fixtures: @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("fixtures")}
  end

  test "every shared fixture derives the documented state", %{fixtures: fixtures} do
    for fixture <- fixtures do
      component = ComponentState.from_projection(fixture["projection"])

      assert component["state"] == fixture["expected_state"],
             "fixture #{inspect(fixture["name"])} derived #{inspect(component["state"])} instead of #{inspect(fixture["expected_state"])}"
    end
  end

  test "the contract state vocabulary matches the published renderer vocabulary", %{fixtures: _fixtures} do
    published = read_published_states()

    assert Enum.sort(ComponentState.states()) == Enum.sort(published)
  end

  test "the dashboard card renders the same state the API publishes", %{fixtures: fixtures} do
    for fixture <- fixtures do
      projection = fixture["projection"]
      row = dashboard_row(projection)

      assert CommandCards.command_state(row) == ComponentState.from_projection(projection)["state"],
             "dashboard card and API component disagree for fixture #{inspect(fixture["name"])}"
    end
  end

  # Reads the `COMMAND_STATES` array out of the package entrypoint so the two
  # vocabularies cannot drift without one of the tests failing.
  defp read_published_states do
    source = Path.expand("../../../../packages/aiur-commands/src/render.mjs", __DIR__) |> File.read!()

    assert [_, states] = Regex.run(~r/export const COMMAND_STATES = \[(.*?)\];/s, source)
    Regex.scan(~r/'([a-z_]+)'/, states) |> Enum.map(fn [_, state] -> state end)
  end

  # The dashboard row is the presenter shape (`atom` keys, no `active_answer`),
  # which is a different input than the API's JSON projection.
  defp dashboard_row(projection) do
    %{
      decision_id: projection["decision_id"],
      version: projection["version"],
      question: projection["question"],
      ticket: atomize(projection["ticket"]),
      blocking: projection["blocking"],
      decision_status: atomize(projection["decision_status"]),
      revision_sequence: projection["revision_sequence"],
      options: Enum.map(projection["options"] || [], &atomize/1),
      recommendation: atomize(projection["recommendation"]),
      artifacts: Enum.map(projection["artifacts"] || [], &atomize/1),
      answer: atomize(projection["answer"]),
      health: atomize(projection["health"])
    }
  end

  defp atomize(nil), do: nil
  defp atomize(value) when is_binary(value), do: String.to_atom(value)
  defp atomize(value) when is_number(value) or is_boolean(value), do: value
  defp atomize(%{} = map), do: Map.new(map, fn {key, value} -> {String.to_atom(key), atomize(value)} end)
  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
end
