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

    test "the restart check greps for the port that block binds" do
      # AC 5's verification step. Same two-literals-that-must-agree shape as the
      # tunnel origin below, and the same reason it matters: if the pinned port
      # changes and this check does not, the operator greps for a port nothing
      # is bound to, sees no output, and concludes the restart *broke* something
      # — or worse, greps for the old port, matches some other process, and
      # signs off on a restart-stability claim that was never tested.
      settings = parsed_daemon_block()
      ports = restart_check_ports()

      refute ports == [], "the runbook no longer documents a restart check for AC 5"

      for port <- ports do
        assert port == settings.server.port,
               "the restart check greps for port #{port} but the documented config binds " <>
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
        ~r/ss -ltn \| grep (\d+)/
        |> Regex.scan(section)
        |> Enum.map(fn [_, port] -> String.to_integer(port) end)

      nil ->
        []
    end
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
