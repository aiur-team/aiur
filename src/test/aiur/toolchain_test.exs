defmodule Aiur.ToolchainTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, Issue, Toolchain}
  alias Aiur.Orchestrator.{DispatchPolicy, State}
  alias Aiur.Toolchain.Probe

  @now ~U[2026-11-01 12:00:00Z]

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-toolchain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "bin"))
    Toolchain.reset()

    on_exit(fn ->
      Toolchain.reset()
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, path: Path.join(root, "bin")}
  end

  # A global npm install: <prefix>/bin/<exe> -> ../lib/node_modules/<package>/cli.
  defp npm_install!(root, exe, package, version) do
    package_dir = Path.join([root, "lib", "node_modules", package])
    write_cli!(package_dir, version)
    link_bin!(root, exe, Path.join(["..", "lib", "node_modules", package, "cli"]))
  end

  # `npm link`: the global package directory is itself a symlink to a checkout.
  defp npm_link!(root, exe, package, version) do
    checkout = Path.join([root, "checkouts", exe])
    write_cli!(checkout, version)
    File.write!(Path.join(checkout, "package.json"), ~s({"name":"#{package}"}))
    global = Path.join([root, "lib", "node_modules", package])
    File.mkdir_p!(Path.dirname(global))
    File.ln_s!(checkout, global)
    link_bin!(root, exe, Path.join(["..", "lib", "node_modules", package, "cli"]))
  end

  defp write_cli!(dir, version) do
    File.mkdir_p!(dir)
    cli = Path.join(dir, "cli")
    File.write!(cli, "#!/bin/sh\necho 'tool #{version}'\n")
    File.chmod!(cli, 0o755)
  end

  defp link_bin!(root, exe, target) do
    bin = Path.join([root, "bin", exe])
    File.rm(bin)
    File.ln_s!(target, bin)
  end

  defp tool(name, package, backends, minimum \\ nil),
    do: %{name: name, exe: name, package: package, backends: backends, minimum: minimum, auto_update?: true}

  defp latest(versions), do: fn package -> Map.get(versions, package) end

  defp issue(backend),
    do: %Issue{id: "t-#{backend}", identifier: "T-#{backend}", title: "t", state: "todo", labels: ["model:#{backend}"], dispatch_authorized?: true, blocked_by: []}

  defp attentions, do: Enum.filter(AlertFeed.list(needs_attention: true), &(&1["topic"] == Toolchain.alert_name()))

  describe "probing a fake PATH" do
    test "an old install, a current install and an npm link are told apart", %{root: root, path: path} do
      npm_install!(root, "aiur-claude", "aiur-claude", "1.1.0")
      npm_install!(root, "codex", "@openai/codex", "0.166.0")
      npm_link!(root, "claude", "@anthropic-ai/claude-code", "2.0.0")
      latest = latest(%{"aiur-claude" => "1.3.0", "@openai/codex" => "0.166.0", "@anthropic-ai/claude-code" => "2.1.0"})

      old = Probe.run(tool("aiur-claude", "aiur-claude", ["claude"], "1.3.0"), path: path, latest: latest)
      current = Probe.run(tool("codex", "@openai/codex", ["codex"]), path: path, latest: latest)
      linked = Probe.run(tool("claude", "@anthropic-ai/claude-code", ["claude-repl"]), path: path, latest: latest)
      missing = Probe.run(tool("aiur", "aiur-cli", []), path: path, latest: latest)

      assert %{version: "1.1.0", kind: :npm, status: :below_minimum, path: old_path} = old
      assert old_path == Path.join(path, "aiur-claude")
      assert %{version: "0.166.0", kind: :npm, status: :current} = current
      assert %{version: "2.0.0", kind: :dev_link, status: :behind, latest: "2.1.0"} = linked
      assert %{kind: :missing, status: :missing, path: nil} = missing
    end

    test "an unreachable registry reports latest unknown, never current", %{root: root, path: path} do
      npm_install!(root, "codex", "@openai/codex", "0.166.0")

      assert %{status: :latest_unknown} = Probe.run(tool("codex", "@openai/codex", ["codex"]), path: path, latest: fn _ -> nil end)
    end
  end

  describe "below minimum" do
    test "raises one attention and holds only that backend's dispatch until fixed", %{root: root, path: path} do
      npm_install!(root, "aiur-claude", "aiur-claude", "1.1.0")
      npm_install!(root, "codex", "@openai/codex", "0.166.0")
      tools = [tool("aiur-claude", "aiur-claude", ["claude"], "1.3.0"), tool("codex", "@openai/codex", ["codex"])]
      opts = [tools: tools, path: path, latest: latest(%{"aiur-claude" => "1.3.0", "@openai/codex" => "0.166.0"}), auto_update?: false, now: @now]

      claude_issue = issue("claude")
      assert DispatchPolicy.dispatch_decision(claude_issue, %State{}, MapSet.new(["todo"]), MapSet.new()) == :dispatch

      Toolchain.check(opts)
      Toolchain.check(opts)

      assert [alert] = attentions()
      assert alert["reason"] =~ "aiur-claude 1.1.0"
      assert alert["reason"] =~ "below 1.3.0"
      assert DispatchPolicy.dispatch_decision(claude_issue, %State{}, MapSet.new(["todo"]), MapSet.new()) == {:skip, :toolchain_hold}
      assert Toolchain.dispatch_decision(issue("codex")) == :dispatch
      assert Toolchain.hold_detail(claude_issue) =~ "aiur-claude 1.1.0 is below the minimum 1.3.0; update: npm install -g aiur-claude@latest"

      npm_install!(root, "aiur-claude", "aiur-claude", "1.3.0")
      Toolchain.check(opts)

      assert [] = attentions()
      assert Toolchain.dispatch_decision(claude_issue) == :dispatch
    end
  end

  describe "auto_update" do
    setup %{root: root} do
      npm_install!(root, "codex", "@openai/codex", "0.165.0")
      :ok
    end

    defp update_opts(path, overrides) do
      Keyword.merge([tools: [tool("codex", "@openai/codex", ["codex"])], path: path, latest: latest(%{"@openai/codex" => "0.166.0"}), auto_update?: true, now: @now], overrides)
    end

    test "updates a behind npm install with the backend held, and new probes see the new binary", %{root: root, path: path} do
      owner = self()

      install = fn package, version ->
        send(owner, {:installed, package, version, Toolchain.dispatch_decision(issue("codex"))})
        npm_install!(root, "codex", "@openai/codex", version)
        :ok
      end

      assert [%{version: "0.166.0", status: :current}] = Toolchain.check(update_opts(path, install: install, running_backends: fn -> [] end))
      assert_received {:installed, "@openai/codex", "0.166.0", {:skip, :toolchain_hold}}
      assert Toolchain.dispatch_decision(issue("codex")) == :dispatch
    end

    test "the published snapshot keeps every tool updated in one pass", %{root: root, path: path} do
      npm_install!(root, "claude", "@anthropic-ai/claude-code", "2.0.0")
      versions = %{"@openai/codex" => "0.166.0", "@anthropic-ai/claude-code" => "2.1.0"}
      exes = %{"@openai/codex" => "codex", "@anthropic-ai/claude-code" => "claude"}
      install = fn package, version -> npm_install!(root, exes[package], package, version) && :ok end
      tools = [tool("codex", "@openai/codex", ["codex"]), tool("claude", "@anthropic-ai/claude-code", ["claude-repl"])]

      Toolchain.check(update_opts(path, tools: tools, latest: latest(versions), install: install, running_backends: fn -> [] end))

      assert [%{name: "codex", status: :current}, %{name: "claude", status: :current}] = Toolchain.snapshot().tools
    end

    test "never updates under a running worker of that backend", %{path: path} do
      install = fn _package, _version -> flunk("installed under a running worker") end

      for running <- [["codex"], [nil], :unavailable] do
        assert [%{version: "0.165.0", status: :behind}] = Toolchain.check(update_opts(path, install: install, running_backends: fn -> running end))
        assert Toolchain.dispatch_decision(issue("codex")) == :dispatch
      end

      assert [%{status: :current}] =
               Toolchain.check(update_opts(path, install: fn _p, _v -> :ok end, running_backends: fn -> ["claude"] end, latest: latest(%{"@openai/codex" => "0.165.0"})))
    end

    test "never replaces an npm link, and is off unless enabled", %{root: root, path: path} do
      install = fn _package, _version -> flunk("replaced a dev link") end
      linked_root = Path.join(root, "linked")
      File.mkdir_p!(Path.join(linked_root, "bin"))
      npm_link!(linked_root, "codex", "@openai/codex", "0.165.0")

      assert [%{kind: :dev_link, status: :behind}] = Toolchain.check(update_opts(Path.join(linked_root, "bin"), install: install, running_backends: fn -> [] end))
      assert [%{kind: :npm, status: :behind}] = Toolchain.check(update_opts(path, install: install, running_backends: fn -> [] end, auto_update?: false))
    end
  end

  describe "status lines" do
    test "render the age, kind and update command for each tool" do
      tools = [
        %{name: "aiur-claude", package: "aiur-claude", backends: ["claude"], minimum: "1.3.0", path: "/b/aiur-claude", version: "1.1.0", kind: :npm, latest: "1.3.0", status: :below_minimum},
        %{name: "codex", package: "@openai/codex", backends: ["codex"], minimum: nil, path: "/b/codex", version: "0.165.0", kind: :npm, latest: "0.166.0", status: :behind},
        %{name: "claude", package: "@anthropic-ai/claude-code", backends: ["claude-repl"], minimum: nil, path: "/b/claude", version: "2.0.0", kind: :standalone, latest: nil, status: :latest_unknown},
        %{name: "aiur", package: "aiur-cli", backends: [], minimum: nil, path: nil, version: nil, kind: :missing, latest: nil, status: :missing}
      ]

      assert Toolchain.status_lines(%{observed_at: @now, tools: tools}, now: DateTime.add(@now, 90, :second)) == [
               "TOOLCHAIN observed_at=2026-11-01T12:00:00Z age_ms=90000",
               "  aiur-claude 1.1.0 (npm) /b/aiur-claude BELOW MINIMUM 1.3.0, claude dispatch held; update: npm install -g aiur-claude@latest",
               "  codex 0.165.0 (npm) /b/codex WARNING behind 0.166.0; update: npm install -g @openai/codex@latest",
               "  claude 2.0.0 (standalone) /b/claude latest unknown",
               "  aiur not on PATH"
             ]
    end

    test "say the toolchain was not checked rather than inventing a state" do
      assert Toolchain.status_lines(nil) == ["TOOLCHAIN unavailable (not checked yet)"]
    end
  end
end
