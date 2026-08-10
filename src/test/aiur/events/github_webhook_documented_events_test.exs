defmodule Aiur.Events.GithubWebhookDocumentedEventsTest do
  @moduledoc """
  Keeps the operator-facing webhook subscription table honest.

  `docs/security/webhook-ingress.md` tells an operator which events to tick when
  registering the webhook. That list is only correct while it matches the set of
  event types `Normalizer` actually has a clause for, and nothing about a drifted
  list looks broken from the outside: unsubscribed events simply never arrive, so
  the ingress guard and the delivery-mode diagnostic both stay green while agents
  silently never wake. This test is the thing that fails instead.
  """

  use ExUnit.Case, async: true

  alias Aiur.Events.GithubWebhook.Normalizer

  @doc_path Path.expand("../../../../docs/security/webhook-ingress.md", __DIR__)
  @repo "acme/widgets"

  # Deliberately wider than the supported set: the unsupported entries are what
  # give the equality assertion below its teeth. A table that listed every event
  # would fail on these rather than passing vacuously.
  @candidate_events ~w(
    issue_comment issues pull_request pull_request_review pull_request_review_comment
    check_suite check_run push create delete fork watch star release
    workflow_run workflow_job status deployment member ping
  )

  test "the documented subscription table is exactly the set the normalizer consumes" do
    documented = documented_events()

    supported = Enum.filter(@candidate_events, &supported?/1)

    assert documented != [], "no subscription table found in #{@doc_path}"
    assert Enum.sort(documented) == Enum.sort(supported)
  end

  test "every documented event is reachable rather than dropped as unsupported" do
    for event <- documented_events() do
      refute match?({:drop, {:unsupported_event, _}}, normalize(event)),
             "#{event} is documented as a subscription but the normalizer has no clause for it"
    end
  end

  test "an undocumented event is still rejected as unsupported" do
    # Guards the negative direction: if `normalize/3` ever started accepting
    # everything, the equality test above could pass by widening rather than by
    # the table being right.
    assert {:drop, {:unsupported_event, "push"}} = normalize("push")
    refute "push" in documented_events()
  end

  defp supported?(event), do: not match?({:drop, {:unsupported_event, _}}, normalize(event))

  # An otherwise-empty payload is enough: a supported event type falls through to
  # its clause and reports a malformed payload, while an unsupported one is
  # rejected on the type alone. Only the type is under test here.
  defp normalize(event) do
    Normalizer.normalize(event, %{"repository" => %{"full_name" => @repo}}, repo: @repo)
  end

  defp documented_events do
    @doc_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) != "| Event | Why |"))
    |> Enum.drop(2)
    |> Enum.take_while(&String.starts_with?(String.trim(&1), "|"))
    |> Enum.map(fn row ->
      row |> String.split("|") |> Enum.at(1) |> String.trim() |> String.trim("`")
    end)
  end
end
