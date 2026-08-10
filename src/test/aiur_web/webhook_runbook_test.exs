defmodule AiurWeb.WebhookRunbookTest do
  @moduledoc """
  Keeps `docs/security/webhook-ingress.md` honest against the code it describes.

  The runbook is operator-facing: someone follows it once, by hand, to publish a
  route and register a webhook. Everything it gets wrong fails *silently* and in
  the same direction — the daemon keeps running, the ingress guard keeps
  reporting a scoped edge, and the delivery-mode diagnostic stays green, while
  deliveries the fleet needs simply never arrive.

  Nothing else in the suite can catch that. Every other test resolves the webhook
  path through `GithubWebhook.path/0` and the event set through the normalizer's
  own clauses, so both stay self-consistent no matter what the doc says. These
  tests are the only place the literal strings an operator types are compared to
  the code that has to agree with them.
  """

  use ExUnit.Case, async: true

  alias Aiur.Events.GithubWebhook.Normalizer
  alias AiurWeb.GithubWebhook

  @repo_root Path.expand("../../..", __DIR__)
  @doc_path Path.join(@repo_root, "docs/security/webhook-ingress.md")
  @guard_path Path.join(@repo_root, "scripts/verify-webhook-ingress")
  @repo "acme/widgets"

  # Deliberately wider than the supported set: the unsupported entries are what
  # give the equality assertion its teeth. A table that listed every GitHub event
  # would fail on these rather than passing vacuously.
  @candidate_events ~w(
    issue_comment issues pull_request pull_request_review pull_request_review_comment
    check_suite check_run push create delete fork watch star release
    workflow_run workflow_job status deployment member ping
  )

  describe "event subscription table" do
    test "is exactly the set the normalizer consumes" do
      documented = documented_events()

      assert documented != [], "no subscription table found in #{@doc_path}"
      assert Enum.sort(documented) == Enum.sort(Enum.filter(@candidate_events, &supported?/1))
    end

    test "lists only events the normalizer can reach" do
      for event <- documented_events() do
        refute match?({:drop, {:unsupported_event, _}}, normalize(event)),
               "#{event} is documented as a subscription but the normalizer has no clause for it"
      end
    end

    test "an undocumented event is still rejected as unsupported" do
      # Guards the negative direction: if `normalize/3` ever started accepting
      # everything, the equality test could pass by widening rather than by the
      # table being correct.
      assert {:drop, {:unsupported_event, "push"}} = normalize("push")
      refute "push" in documented_events()
    end
  end

  describe "webhook path" do
    test "the documented ingress rule publishes exactly the route the app serves" do
      # The rule is a Go regexp anchored at both ends. Anchoring is load-bearing:
      # an unanchored rule would also match longer paths that merely contain this
      # one, which is how a path-scoped tunnel accidentally publishes a
      # neighbouring route.
      rule = ingress_rule_path()

      assert String.starts_with?(rule, "^") and String.ends_with?(rule, "$"),
             "the ingress rule must be anchored at both ends, got: #{rule}"

      assert rule |> String.trim_leading("^") |> String.trim_trailing("$") == GithubWebhook.path()
    end

    test "the ingress guard checks the route the app actually serves" do
      # If these drift apart the guard keeps exiting 0 while asserting things
      # about a path nothing serves — a green run that proves nothing.
      assert guard_webhook_path() == GithubWebhook.path()
    end

    test "the payload URL an operator pastes into GitHub ends in that same path" do
      doc = File.read!(@doc_path)

      assert doc =~ "**Payload URL:** `https://hooks.<domain>#{GithubWebhook.path()}`"
    end
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

  defp ingress_rule_path do
    [_, rule] = Regex.run(~r/^\s*path:\s*(\S+)\s*$/m, File.read!(@doc_path))
    rule
  end

  defp guard_webhook_path do
    [_, path] = Regex.run(~r/^webhook_path="([^"]+)"/m, File.read!(@guard_path))
    path
  end
end
