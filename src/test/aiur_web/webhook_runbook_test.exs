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

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Config.Schema
  alias Aiur.Events.GithubWebhook.Normalizer
  alias Aiur.ProviderMeterProjection
  alias Aiur.Webhooks.DeliveryMode
  alias Aiur.Webhooks.ModePresenter
  alias AiurWeb.GithubWebhook

  @repo_root Path.expand("../../..", __DIR__)
  @doc_path Path.join(@repo_root, "docs/security/webhook-ingress.md")
  @guard_path Path.join(@repo_root, "scripts/verify-webhook-ingress")
  @harness_path Path.join(@repo_root, "scripts/test-webhook-ingress.sh")
  @api_prefix "/api/v1"

  # `StreamdeckSessionController` serves exactly one route, `POST
  # /api/v1/streamdeck/token`, and there is no `match(:*, ...)` clause for it — so
  # a GET falls to the router's catch-all and no GET probe can ever reach the
  # controller. The guard probes with GET on purpose (it must not be able to pause
  # an agent or mint a token as a side effect of verifying scoping), so this
  # surface is genuinely unprobeable from here rather than merely unprobed.
  @unprobeable [AiurWeb.StreamdeckSessionController]
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
    {~r/`poll_widen_factor` defaults to `([0-9.]+)`/, :float, Schema.Webhooks, :poll_widen_factor, "webhooks.poll_widen_factor"},
    {~r/`silence_threshold_seconds` \(default ([0-9]+)\)/, :integer, Schema.Webhooks, :silence_threshold_seconds, "webhooks.silence_threshold_seconds"},
    # Load-bearing for AC 5. The whole "Pin the daemon's port" step exists
    # because this default means a new OS-assigned port on every restart; if it
    # ever became a fixed port, that rationale would be wrong rather than merely
    # stale.
    {~r/`Aiur\.Config\.Schema\.Server` defaults `port` to `([0-9]+)`/, :integer, Schema.Server, :port, "server.port"}
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

  describe "the daemon config block an operator pastes" do
    # The `documented defaults` block above proves the runbook quotes the
    # schema's default correctly. It does not prove the YAML the runbook tells
    # an operator to *write* ever reaches that field, and those are different
    # claims: `Schema.parse/1` casts embeds by key, so a section that is renamed
    # or renested leaves the pasted block matching nothing. Ecto drops unknown
    # keys silently — no error, no warning — and `server.port` falls straight
    # back to its `0` default.
    #
    # That is AC 5 failing invisibly. The operator follows the runbook, the
    # daemon takes a fresh OS-assigned port on every restart, and the tunnel
    # starts 502ing at a hostname that is still perfectly stable. Nothing else
    # in the suite touches this: every other test constructs config maps in
    # code, so the doc's own YAML is never once fed to the parser.
    test "parses through the real loader path and actually pins the port" do
      settings = parsed_daemon_block()

      refute settings.server.port == %Schema.Server{}.port,
             "the runbook's `server:` block no longer changes server.port away from its " <>
               "default — the pasted YAML is being silently ignored, so the daemon still " <>
               "takes a new port on every restart and AC 5 is false"

      assert settings.server.port > 0
    end

    test "keeps the daemon on loopback" do
      # Binding a routable interface is what the runbook explicitly tells the
      # operator not to do: the tunnel dials from the same machine, and a
      # routable bind additionally trips the dashboard Basic Auth boot guard.
      assert parsed_daemon_block().server.host in ~w(127.0.0.1 ::1 localhost)
    end

    test "the restart check pins the same port that block binds" do
      # AC 5's verification step. Same two-literals-that-must-agree shape as the
      # tunnel origin below, and the same reason it matters: if the pinned port
      # changes and this check does not, the operator compares against a port
      # nothing is bound to, sees no output, and concludes the restart *broke*
      # something — or worse, matches some other process and signs off on a
      # restart-stability claim that was never tested.
      #
      # This test can only hold the document to its own numbers. It cannot see a
      # deployment bound somewhere else, which is why the runbook's own check now
      # discovers the live port and reports MISMATCH rather than assuming it.
      settings = parsed_daemon_block()
      ports = restart_check_ports()

      refute ports == [], "the runbook no longer documents a restart check for AC 5"

      for port <- ports do
        assert port == settings.server.port,
               "the restart check pins port #{port} but the documented config binds " <>
                 "#{settings.server.port}"
      end
    end

    test "the runbook's claim that CI checks the restart invariant is true" do
      # The runbook now tells the reader the restart invariant is "checked on
      # every CI run rather than only when someone remembers to redo the manual
      # procedure". That sentence is the whole reason an operator would trust AC
      # 5 without re-running the procedure by hand — and it is a claim about a
      # *different file*, which is the drift shape this document keeps producing.
      #
      # Deleting either direction from the harness leaves every other check on
      # this branch green: the harness still exits 0 with fewer cases, and the
      # paragraph goes on asserting a coverage that is no longer there. Nothing
      # else on the branch can see it, because no other test reads the harness.
      harness = File.read!(@harness_path)

      assert harness =~ ~r/^start_tier edge --origin-port/m,
             "#{@harness_path} no longer runs the daemon behind a separate edge, so " <>
               "nothing in CI can distinguish a moved origin from a moved hostname"

      # Both directions, and they are not interchangeable. The pinned case alone
      # would pass against a guard that never fails; the unpinned case alone
      # would pass against one that never succeeds.
      assert harness =~ ~r/^start_tier origin --port "\$origin_port"$/m,
             "#{@harness_path} no longer restarts a PINNED origin, so the passing " <>
               "direction of AC 5 is unchecked"

      assert harness =~ ~r/expected the guard to REJECT the same URL after an UNPINNED/,
             "#{@harness_path} no longer checks that an UNPINNED restart breaks the " <>
               "URL, so a guard that passed unconditionally would look like a clean AC 5"
    end

    # Deliberately NOT pinned here: that the guard's moved-origin branch names
    # `server.port`. The obvious string pin — read the reason out of the
    # harness's `grep -Fq`, assert it appears in the guard — was written, and
    # then failed its own mutation check: rewording the 5xx branch left the test
    # green, because `pin server.port in .aiur/config` also appears in the `000)`
    # branch, so the assertion was satisfied by a branch other than the one under
    # test. The harness already catches that mutation by *execution* (it greps
    # the guard's real output on a moved origin and fails), which is strictly
    # stronger than any string match. A weaker duplicate that cannot catch its
    # own target is the exact shape this branch has spent sixteen findings
    # removing, so it was removed rather than shipped.

    test "every pinned= literal in the runbook agrees with that block" do
      # More than one section now assigns `pinned=` — the restart check and the
      # bind check under "What is exposed". They are separate snippets an
      # operator runs independently, so each has to carry its own value rather
      # than inherit one from a section a page away. That makes them a drift
      # pair: correcting the port in one place and not the other leaves a
      # document that is right where you look and wrong where you don't.
      settings = parsed_daemon_block()
      ports = all_pinned_ports()

      assert length(ports) >= 2,
             "expected the restart check and the bind check to each pin a port; found " <>
               "#{length(ports)}"

      for port <- ports do
        assert port == settings.server.port,
               "a snippet pins port #{port} but the documented config binds " <>
                 "#{settings.server.port}"
      end
    end

    test "the tunnel's origin is the address that block binds" do
      # Two YAML blocks, a page apart, that must agree by hand. If they drift,
      # `cloudflared tunnel ingress validate` still passes — it does not dial
      # the origin — and every ingress rule check still reports the right
      # service. The failure only shows up as a 502 on live deliveries.
      settings = parsed_daemon_block()
      %URI{host: host, port: port} = URI.parse(tunnel_origin())

      assert {host, port} == {settings.server.host, settings.server.port},
             "the tunnel forwards to #{host}:#{port} but the documented config binds " <>
               "#{settings.server.host}:#{settings.server.port}"
    end
  end

  describe "the repo-registration block an operator pastes" do
    # Same silent-drop mechanic as the `server:` block above, with a worse
    # consequence. If `webhooks` or `repos` is ever renamed or renested, the
    # pasted block registers nothing: the repo never leaves
    # `configured_unproven`, its polls never widen, and #1675's entire quota
    # mitigation quietly does not happen.
    #
    # Nothing looks broken from outside — deliveries still arrive and are still
    # accepted, so the ingress guard and the delivery-mode diagnostic both stay
    # green. This is already the step the runbook flags as most likely to be
    # skipped; it should not also be the step that can fail after being done.
    test "actually registers the repo it lists" do
      settings = parsed_config_block("webhooks")

      refute settings.webhooks.repos == %Schema.Webhooks{}.repos,
             "the runbook's `webhooks:` block no longer populates webhooks.repos — the pasted " <>
               "YAML is being silently ignored, so a repo registered by following the runbook " <>
               "stays in configured_unproven and never widens its poll interval"

      assert settings.webhooks.repos == ["owner/name"]
    end
  end

  describe "the secret variable name the runbook tells an operator to set" do
    test "every mention agrees with the name .env.example documents" do
      # `github_webhook_test.exs` already pins `.env.example` to the name the
      # receiver reads, behaviourally. Nothing pinned the *runbook's* copies, and
      # there are four of them: the generate step, the leak check, the GitHub
      # form's "Secret" field, and the exposure statement.
      #
      # So a rename is caught in `.env.example` and silently missed here. The
      # operator follows the runbook, exports the old name, and every delivery is
      # rejected with a 401 — while the suite stays green, because the pin that
      # exists is satisfied. Same drift-pair shape as the `pinned=` ports, with
      # four literals instead of two.
      documented = env_example_secret_name()
      mentioned = documented_secret_names()

      refute mentioned == [],
             "#{@doc_path} no longer names a webhook secret variable for an operator to set"

      assert mentioned == [documented],
             "the runbook names #{inspect(mentioned)} but .env.example documents " <>
               "#{inspect(documented)}"
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
    @load_bearing ~w(
      / /decisions /build-orders /analytics /streamdeck /api/v1/state
      /api/v1/1/pause /api/v1/1/resume /api/v1/1/messages /api/v1/1/claude-hook
      /api/v1/1/events /api/v1/pane/hide
      /api/v1/decisions/1/decide /api/v1/decisions/1/enrich /api/v1/decisions/1/revise
    )

    # Knowingly vacuous under GET: the daemon has no GET clause for either, so it
    # answers 404 itself and a pass proves nothing an edge deny would not. They
    # stay because `/api/v1/` is the tripwire for an over-broad prefix rule, and
    # dropping the token path would read as reducing coverage. Naming them here is
    # what keeps the rest of the list honest — anything *not* named must resolve.
    @known_weak ~w(/api/v1/streamdeck/token /api/v1/)

    test "the load-bearing entries all resolve to real routes, not the catch-all" do
      for path <- @load_bearing do
        assert path in guard_denied_paths(),
               "#{path} is load-bearing for the guard but is no longer in its denied_paths list"

        assert real_route?(path),
               "#{path} no longer resolves to a real route, so the guard's assertion about it " <>
                 "now passes vacuously via the router's /*path catch-all"
      end
    end

    test "no unmarked entry is vacuous" do
      # The pin above only speaks for the paths it names, so a *new* entry could
      # be added that the daemon 404s itself — indistinguishable from an edge
      # deny, and therefore evidence of nothing while reading like evidence of
      # something. Two such entries already existed and went unnoticed until they
      # were measured. This generalises the check to the whole list.
      for path <- guard_denied_paths(), path not in @known_weak do
        assert real_route?(path),
               "#{path} is in the guard's denied_paths but resolves to the router's /*path " <>
                 "catch-all, so the daemon 404s it too and the assertion cannot fail. Either " <>
                 "probe a path the daemon actually serves, or add it to @known_weak with a " <>
                 "comment saying why it stays."
      end
    end

    test "each knowingly-weak entry is still marked as such in the guard" do
      # Two-sided: the reason an entry is exempt lives in the script an operator
      # reads, not only in this test. If the marker is dropped, the next reader
      # takes a vacuous line for a real assertion.
      guard = File.read!(@guard_path)

      for path <- @known_weak do
        line = Enum.find(String.split(guard, "\n"), &String.contains?(&1, "\"#{path}\""))

        assert line, "#{path} is exempted as weak but no longer appears in #{@guard_path}"

        assert line =~ "weak",
               "#{path} is exempted from the vacuity check but its line in #{@guard_path} no " <>
                 "longer says so: #{String.trim(line)}"
      end
    end

    test "every /api/v1 controller is probed or explicitly named unprobeable" do
      # The list is hand-maintained and the router grows. A new API controller
      # mounted under /api/v1 is published by exactly the same over-broad ingress
      # rule as the existing ones, and nothing would have probed it — the guard
      # would still print `exposure is scoped` while the new surface was live.
      for controller <- api_controllers() do
        assert controller in @unprobeable or
                 Enum.any?(guard_denied_paths(), &(controller_for(&1) == controller)),
               "#{inspect(controller)} serves #{@api_prefix} routes but no path in the guard's " <>
                 "denied_paths reaches it, so an over-broad ingress rule would publish it " <>
                 "undetected. Add a GET-safe representative path, or add it to @unprobeable " <>
                 "with the reason."
      end
    end

    test "the webhook path is not in the denied list" do
      # It is the one path that must be reachable; asserting it is denied would
      # invert the whole check.
      refute GithubWebhook.path() in guard_denied_paths()
    end
  end

  # AC 3's confirmation step. This line is the operator's only end-to-end proof
  # that a real delivery reached the daemon, and it is the one diagnostic whose
  # internal vocabulary and on-screen vocabulary differ: the states are atoms in
  # the code and prose in the output. A runbook that quotes the atom sends the
  # operator grepping for a string the CLI never prints, and finding nothing
  # looks exactly like a delivery that never arrived.
  describe "the delivery-mode line the runbook tells an operator to read" do
    setup do
      projection = :"runbook_usage_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        start_supervised({ProviderMeterProjection, [name: projection, subscribe?: false, clock: fn -> ~U[2026-07-27 12:05:00Z] end]})

      %{projection: projection}
    end

    test "every example line it shows is one the CLI really prints", ctx do
      output = usage_output(ctx.projection)
      documented = documented_delivery_lines()

      # Presence, not just agreement: a runbook that dropped the example
      # entirely would otherwise satisfy an empty `for` and pass.
      refute documented == [],
             "#{@doc_path} no longer shows an example `events` line for confirming a delivery landed"

      for line <- documented do
        assert output =~ line, "the runbook shows\n  #{line}\nbut the CLI prints:\n#{output}"
      end
    end

    test "the raw state atom it warns is never printed really is absent", ctx do
      # The unproven repo is in the fixture, so this is the run where the atom
      # would appear if the CLI ever started rendering it instead of the label.
      refute usage_output(ctx.projection) =~ "configured_unproven"
    end
  end

  # AC 6: "documented well enough to redo on a new machine." Every pin above
  # checks a value the runbook *states*. These check the things it tells a reader
  # to go *look at* — the modules its security argument rests on, the reference
  # doc it defers to, and the scripts it says to run. All of them are correct
  # today and none of them had a test, so a rename or a move lands with the whole
  # suite green while the runbook quietly starts citing code that is not there.
  #
  # The person who finds out is the one following it on a new machine, and they
  # are the worst-placed to diagnose it: a reference that resolves to nothing is
  # indistinguishable from their own mistake, on a document whose entire purpose
  # is to be trusted while they cannot yet verify anything themselves.
  describe "the things the runbook points a reader at" do
    test "every module it names exists" do
      refs = documented_code_refs()

      refute refs == [], "#{@doc_path} no longer names any module — the regex or the doc has moved"

      for {ref, module, _fun, _arity} <- refs do
        assert Code.ensure_loaded?(module), "the runbook cites `#{ref}` but #{inspect(module)} does not exist"
      end
    end

    test "every function it names is exported at the arity it names" do
      for {ref, module, fun, arity} <- documented_code_refs(), not is_nil(fun) do
        assert Code.ensure_loaded?(module) and function_exported?(module, fun, arity),
               "the runbook cites `#{ref}` but #{inspect(module)} exports no #{fun}/#{arity}"
      end
    end

    test "the reference doc it defers to is where it says" do
      links = documented_relative_links()

      refute links == [], "#{@doc_path} no longer links the configuration reference it defers to"

      for {link, path} <- links do
        assert File.exists?(path), "the runbook links `#{link}`, which resolves to no file"
      end
    end

    test "the scripts it tells an operator to run exist and are runnable" do
      scripts = documented_scripts()

      refute scripts == [], "#{@doc_path} no longer names a script for an operator to run"

      for {ref, path} <- scripts do
        assert File.exists?(path), "the runbook says to run `#{ref}`, which does not exist"

        # The runbook invokes it directly rather than through `bash`, so a file
        # committed without its mode bit fails on a fresh clone and nowhere else.
        assert Bitwise.band(File.stat!(path).mode, 0o111) != 0,
               "the runbook says to run `#{ref}` directly but it is not executable"
      end
    end
  end

  # Matches a backticked `Module.Name` or `Module.Name.fun/arity`. Restricted to
  # a capitalised first segment so the runbook's config keys (`webhooks.repos`)
  # and hostnames (`hooks.<domain>`) are not mistaken for code.
  @code_ref ~r/`((?:[A-Z][A-Za-z0-9]*)(?:\.[A-Za-z0-9_]+)+(?:\/[0-9]+)?)`/

  # Any `AIUR_*SECRET` token, wherever it appears — prose, a shell snippet, or a
  # field label — since an operator will copy whichever one they read first.
  @secret_var ~r/AIUR_[A-Z0-9_]*SECRET/

  defp documented_secret_names do
    @doc_path
    |> File.read!()
    |> then(&Regex.scan(@secret_var, &1))
    |> List.flatten()
    |> Enum.uniq()
  end

  defp env_example_secret_name do
    path = Path.join(@repo_root, ".env.example")

    case Regex.run(~r/^(AIUR_[A-Z0-9_]*SECRET)=/m, File.read!(path)) do
      [_, name] -> name
      nil -> flunk("#{path} no longer documents an AIUR_*SECRET variable")
    end
  end

  defp documented_code_refs do
    @doc_path
    |> File.read!()
    |> then(&Regex.scan(@code_ref, &1))
    |> Enum.map(fn [_, ref] -> ref end)
    |> Enum.uniq()
    |> Enum.map(&parse_code_ref/1)
  end

  defp parse_code_ref(ref) do
    case String.split(ref, "/") do
      [path, arity] ->
        {segments, [fun]} = path |> String.split(".") |> Enum.split(-1)
        {ref, Module.concat(segments), String.to_atom(fun), String.to_integer(arity)}

      [path] ->
        {ref, path |> String.split(".") |> Module.concat(), nil, nil}
    end
  end

  defp documented_relative_links do
    @doc_path
    |> File.read!()
    |> then(&Regex.scan(~r/\]\((?!https?:)([^)#]+)\)/, &1))
    |> Enum.map(fn [_, link] -> {link, Path.expand(link, Path.dirname(@doc_path))} end)
    |> Enum.uniq()
  end

  defp documented_scripts do
    @doc_path
    |> File.read!()
    |> then(&Regex.scan(~r/(scripts\/[A-Za-z0-9_.-]+)/, &1))
    |> Enum.map(fn [_, ref] -> {ref, Path.join(@repo_root, ref)} end)
    |> Enum.uniq()
  end

  defp usage_output(projection) do
    capture_io(fn -> AgentControlCLI.usage(projection, delivery_modes: documented_example_rows()) end)
  end

  # The repo names and the delivery timestamp are the doc's own, so its example
  # lines can be compared verbatim against real output instead of through a
  # loosened pattern that would tolerate the drift this exists to catch.
  defp documented_example_rows do
    {proven, :proven} =
      "owner/name"
      |> DeliveryMode.new(configured?: true)
      |> DeliveryMode.record_delivery(~U[2026-07-27 12:00:00Z])

    ModePresenter.rows(modes: [proven, DeliveryMode.new("owner/other", configured?: true)])
  end

  defp documented_delivery_lines do
    @doc_path
    |> File.read!()
    |> then(&Regex.scan(~r/```text\n(.*?)```/s, &1))
    |> Enum.flat_map(fn [_, block] -> String.split(block, "\n", trim: true) end)
    |> Enum.filter(&String.starts_with?(&1, "events "))
  end

  defp real_route?(path) do
    case Phoenix.Router.route_info(AiurWeb.Router, "GET", path, "localhost") do
      :error -> false
      %{route: route} -> route != "/*path"
      _other -> false
    end
  end

  # Distinct controllers serving anything under /api/v1, minus the webhook
  # receiver itself — that one is the route the tunnel is *supposed* to publish.
  defp api_controllers do
    AiurWeb.Router.__routes__()
    |> Enum.filter(&String.starts_with?(&1.path, @api_prefix))
    |> Enum.map(& &1.plug)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == AiurWeb.GithubWebhookController))
  end

  # Which controller a GET on this path actually reaches. Deliberately resolved
  # through the router rather than by string-matching the path, because a path
  # that looks like it belongs to a controller can fall through to the catch-all —
  # which is the whole mistake `no unmarked entry is vacuous` exists to catch.
  defp controller_for(path) do
    case Phoenix.Router.route_info(AiurWeb.Router, "GET", path, "host") do
      %{plug: plug, route: route} when route != "/*path" -> plug
      _other -> nil
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

  defp parsed_daemon_block, do: parsed_config_block("server")

  # Mirrors production exactly: `Aiur.Workflow` hands `YamlElixir` output to
  # `Schema.parse/1`, so decoding the doc's own fenced block the same way is the
  # real path, not a re-implementation of it.
  defp parsed_config_block(top_level_key) do
    yaml =
      @doc_path
      |> File.read!()
      |> then(&Regex.scan(~r/```yaml\n(.*?)```/s, &1))
      |> Enum.map(fn [_, block] -> block end)
      |> Enum.find(&String.starts_with?(&1, top_level_key <> ":"))

    refute is_nil(yaml),
           "#{@doc_path} no longer contains a `#{top_level_key}:` YAML block for an operator to paste"

    assert {:ok, decoded} = YamlElixir.read_from_string(yaml)
    assert {:ok, settings} = Schema.parse(decoded)
    settings
  end

  # Scoped to the restart section alone: `4099` appears elsewhere in the runbook
  # (the config block, the tunnel origin), and matching those here would make
  # this test pass on a document that had lost its restart check entirely.
  defp restart_check_ports do
    doc = File.read!(@doc_path)

    case Regex.run(~r/### Verify the URL survives a restart\n(.*?)(?=\n## )/s, doc) do
      [_, section] ->
        # The check assigns the pinned port once and compares the observed port
        # against that variable, rather than grepping for the literal in each
        # step. That shape is deliberate: a bare `grep <port>` against a daemon
        # bound elsewhere prints nothing both before and after the restart, and
        # two empty results compare equal — the check silently passes in exactly
        # the case it exists to catch.
        ~r/^pinned=(\d+)$/m
        |> Regex.scan(section)
        |> Enum.map(fn [_, port] -> String.to_integer(port) end)

      nil ->
        []
    end
  end

  # Whole-document, unlike restart_check_ports/0 above: this one is asking
  # whether every snippet agrees, not whether a particular section still exists.
  defp all_pinned_ports do
    ~r/^\s*pinned=(\d+)$/m
    |> Regex.scan(File.read!(@doc_path))
    |> Enum.map(fn [_, port] -> String.to_integer(port) end)
  end

  defp tunnel_origin do
    case Regex.run(~r/^\s*service:\s*(http[^\s]+)\s*$/m, File.read!(@doc_path)) do
      [_, origin] -> origin
      nil -> flunk("#{@doc_path} no longer documents an http origin for the tunnel")
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
