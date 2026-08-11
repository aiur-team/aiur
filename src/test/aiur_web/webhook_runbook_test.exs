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

  # Every entry is a number the runbook states outright and an operator acts on.
  # They drift silently: the doc and the schema have no other point of contact,
  # so a default can move under the runbook without any test noticing. #1772 did
  # exactly that to `poll_widen_factor` — moved it 1.0 -> 2.0, leaving the doc
  # asserting that listing a repo "changes no poll interval on its own", the
  # opposite of what now happens.
  @documented_defaults [
    {~r/`poll_widen_factor` defaults to `([0-9.]+)`/, :float, Aiur.Config.Schema.Webhooks, :poll_widen_factor, "webhooks.poll_widen_factor"},
    {~r/`silence_threshold_seconds` \(default ([0-9]+)\)/, :integer, Aiur.Config.Schema.Webhooks, :silence_threshold_seconds, "webhooks.silence_threshold_seconds"},
    # Load-bearing for AC 5. The whole "Pin the daemon's port" step exists
    # because this default means a new OS-assigned port on every restart; if it
    # ever became a fixed port, that rationale would be wrong rather than merely
    # stale.
    {~r/`Aiur\.Config\.Schema\.Server` defaults `port` to `([0-9]+)`/, :integer, Aiur.Config.Schema.Server, :port, "server.port"}
  ]

  describe "documented defaults" do
    for {regex, type, module, field, name} <- @documented_defaults do
      test "the documented #{name} default is the schema's actual default" do
        documented = documented_default(unquote(Macro.escape(regex)), unquote(type))
        actual = Map.fetch!(struct!(unquote(module)), unquote(field))

        assert documented == actual,
               "runbook documents #{unquote(name)} default #{documented}, " <>
                 "schema default is #{actual}"
      end
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

  describe "guard denied-path list" do
    # The guard's own header explains the asymmetry it lives with: it reads
    # "answered with $deny_status" as "not routed through", and the daemon 404s
    # some of these paths itself, so those entries are weak evidence. The
    # load-bearing entries are the ones the daemon answers for — a forwarding
    # tunnel cannot make those look like an edge deny.
    #
    # That distinction is exactly what a route rename erases. Rename
    # `/analytics` and the guard still probes `/analytics`, the router's trailing
    # `/*path` catch-all 404s it, and the assertion passes — vacuously, on a path
    # nothing serves, while the real route goes unprobed. Nothing else notices:
    # the guard still exits 0 and still prints `exposure is scoped`.
    @load_bearing ~w(/ /decisions /build-orders /analytics /streamdeck /api/v1/state)

    test "the load-bearing entries all resolve to real routes, not the catch-all" do
      for path <- @load_bearing do
        assert path in guard_denied_paths(),
               "#{path} is load-bearing for the guard but is no longer in its denied_paths list"

        assert real_route?(path),
               "#{path} no longer resolves to a real route, so the guard's assertion about it " <>
                 "now passes vacuously via the router's /*path catch-all"
      end
    end

    test "the webhook path is not in the denied list" do
      # It is the one path that must be reachable; asserting it is denied would
      # invert the whole check.
      refute GithubWebhook.path() in guard_denied_paths()
    end
  end

  defp real_route?(path) do
    case Phoenix.Router.route_info(AiurWeb.Router, "GET", path, "localhost") do
      :error -> false
      %{route: route} -> route != "/*path"
      _other -> false
    end
  end

  defp guard_denied_paths do
    [_, block] = Regex.run(~r/^denied_paths=\((.*?)^\)/ms, File.read!(@guard_path))

    Regex.scan(~r/"([^"]+)"/, block) |> Enum.map(fn [_, p] -> p end)
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

  # Fails loudly on a missing match rather than defaulting: a doc that stopped
  # stating the number at all would otherwise pass this whole describe block.
  defp documented_default(regex, type) do
    case Regex.run(regex, File.read!(@doc_path)) do
      [_, value] when type == :float -> String.to_float(value)
      [_, value] when type == :integer -> String.to_integer(value)
      nil -> flunk("#{@doc_path} no longer states a default matching #{inspect(regex)}")
    end
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
