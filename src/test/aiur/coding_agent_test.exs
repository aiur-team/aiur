defmodule Aiur.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Usage.Headless.Catalog
  alias Aiur.Usage.Pricing.Dimensions

  defp issue(labels), do: %Issue{labels: labels}

  describe "provider presentation descriptors (registry-driven rendering)" do
    test "provider_families/0 lists families in card order, deduped across a shared family" do
      # claude and claude-repl share family :claude, so it appears once.
      assert CodingAgent.provider_families() == [:codex, :claude, :kimi, :deepseek, :openrouter, :muse, :fake]
    end

    test "default fallback is owned by the default backend registry entry" do
      assert CodingAgent.default_backend() == "codex"
      assert CodingAgent.default_rate_limit_fallback() == "claude"
    end

    test "provider_family_map/0 keys usage attribution by registered backend" do
      assert CodingAgent.provider_family_map() == %{
               "codex" => :codex,
               "claude" => :claude,
               "kimi" => :kimi,
               "deepseek" => :deepseek,
               "openrouter" => :openrouter,
               "muse" => :muse,
               "fake" => :fake
             }
    end

    test "provider_descriptor/1 exposes the fields every provider surface renders from" do
      codex = CodingAgent.provider_descriptor(:codex)
      assert codex.label == "Codex"
      assert codex.logo == "/provider-assets/codex-color.svg"
      assert codex.token_icon == "/provider-assets/claude-token.svg"
      assert codex.css_class == "is-codex"

      claude = CodingAgent.provider_descriptor(:claude)
      assert claude.label == "Claude"
      assert claude.logo == "/provider-assets/claude-symbol.svg"
      assert claude.token_icon == "/provider-assets/codex-token.svg"
      assert claude.css_class == "is-claude"

      assert CodingAgent.provider_descriptor(:kimi).label == "Kimi"
      assert CodingAgent.provider_descriptor(:deepseek).label == "DeepSeek"
      assert CodingAgent.provider_descriptor(:openrouter).label == "OpenRouter"
    end

    test "provider_descriptor/1 is nil for an unknown provider (surfaces fall back generically)" do
      assert CodingAgent.provider_descriptor(:nonesuch) == nil
    end

    test "provider_descriptors/0 carries the resolved provider family atom and is card-ordered" do
      assert [
               %{provider: :codex, order: 0},
               %{provider: :claude, order: 1},
               %{provider: :kimi, order: 2},
               %{provider: :deepseek, order: 3},
               %{provider: :openrouter, order: 4},
               %{provider: :muse, order: 5},
               %{provider: :fake, order: 99}
             ] =
               CodingAgent.provider_descriptors()
    end

    test "provider descriptor owns metering, pricing, and account-generation policies" do
      assert %{dimensions: %{context_tier: %{required: true}}} = CodingAgent.provider_pricing(:codex)
      assert %{dimensions: %{cache_write_duration: %{required: true}}} = CodingAgent.provider_pricing(:claude)

      assert %{trusted_sources: [:codex_app_server]} = CodingAgent.provider_account_generation(:codex)
      assert %{trusted_sources: [:claude_app_server]} = CodingAgent.provider_account_generation(:claude)

      assert Dimensions.from_options(:codex, []) == %{context_tier: nil, cache_write_duration: :not_applicable}
      assert Dimensions.from_options(:claude, []) == %{context_tier: :not_applicable, cache_write_duration: nil}

      assert Catalog.adapters_for(:codex) == [Aiur.Usage.Headless.Codex.ThreadUsage, Aiur.Usage.Headless.Codex.TurnUsage]
      assert Catalog.adapters_for(:claude) == [Aiur.Usage.Headless.Claude.RequestUsage]
      assert Catalog.adapters_for(:fake) == [Aiur.Usage.Headless.Fake.RequestUsage]
      assert Catalog.adapters_for(:kimi) == [Aiur.Usage.Headless.Kimi.RequestUsage]
      assert Catalog.adapters_for(:deepseek) == [Aiur.Usage.Headless.DeepSeek.RequestUsage]
      assert Catalog.adapters_for(:openrouter) == [Aiur.Usage.Headless.OpenRouter.RequestUsage]
      assert Dimensions.validate(:fake, Dimensions.from_options(:fake, [])) == :ok
    end
  end

  describe "registry dispatch" do
    test "known_backends comes from the registry" do
      assert Enum.sort(CodingAgent.known_backends()) == [
               "claude",
               "claude-repl",
               "codex",
               "deepseek",
               "fake",
               "kimi",
               "muse",
               "openrouter"
             ]
    end

    test "DeepSeek stays registered for meters but requires an explicit dispatch opt-in" do
      assert "deepseek" in CodingAgent.known_backends()
      refute "deepseek" in CodingAgent.dispatchable_backends()
      assert "deepseek" in CodingAgent.dispatchable_backends(%{"deepseek" => %{"enabled" => true}})
      refute "deepseek" in CodingAgent.configurable_backends()
      refute CodingAgent.override_backend(issue(["model:deepseek"]))
    end

    test "adapter and transcript_module resolve per backend" do
      assert CodingAgent.adapter("claude") == Aiur.Claude.CodingAgent
      assert CodingAgent.adapter("codex") == Aiur.Codex.CodingAgent
      assert CodingAgent.adapter("claude-repl") == Aiur.Claude.ReplAgent
      assert CodingAgent.transcript_module("claude") == Aiur.Claude.Transcript
      assert CodingAgent.transcript_module("codex") == Aiur.Codex.Transcript
      assert CodingAgent.transcript_module("claude-repl") == Aiur.Claude.Transcript
      assert CodingAgent.adapter("kimi") == Aiur.OpenAICompat.CodingAgent
      assert CodingAgent.adapter("deepseek") == Aiur.OpenAICompat.CodingAgent
      assert CodingAgent.adapter("openrouter") == Aiur.OpenAICompat.CodingAgent
      assert CodingAgent.transcript_module("kimi") == Aiur.OpenAICompat.Transcript
    end

    test "family_for keeps transport names separate from agent family" do
      assert CodingAgent.family_for("codex") == "codex"
      assert CodingAgent.family_for("claude") == "claude"
      assert CodingAgent.family_for("claude-repl") == "claude"
      assert CodingAgent.family_for("kimi") == "kimi"
      assert CodingAgent.family_for("deepseek") == "deepseek"
      assert CodingAgent.family_for("openrouter") == "openrouter"
      assert CodingAgent.family_for("unknown") == nil
    end

    test "delivery-policy defaults come from the registry" do
      assert CodingAgent.can_interrupt?("codex")
      assert CodingAgent.safe_checkpoints("codex") == [:notification, :tool_result]
      assert CodingAgent.safe_checkpoints("claude") == [:notification]
      refute CodingAgent.can_interrupt?("kimi")
      assert CodingAgent.safe_checkpoints("kimi") == [:notification, :tool_result]
      # The REPL holds nothing at a checkpoint, but Ctrl+C to its pane is
      # an out-of-band interrupt, so it advertises the capability.
      assert CodingAgent.can_interrupt?("claude-repl")
      assert CodingAgent.safe_checkpoints("claude-repl") == []
    end

    test "control confirmation is declared by each supported backend" do
      assert CodingAgent.control_application_confirmation("codex") == :confirmed
      assert CodingAgent.control_application_confirmation("claude") == :confirmed
      assert CodingAgent.control_application_confirmation("claude-repl") == :confirmed
      assert CodingAgent.control_application_confirmation("kimi") == :confirmed
      assert CodingAgent.control_application_confirmation("deepseek") == :confirmed
      assert CodingAgent.control_application_confirmation("openrouter") == :confirmed
      assert CodingAgent.control_application_confirmation("unknown") == :unsupported
    end

    test "effort vocabulary comes from the registry" do
      assert CodingAgent.efforts("codex") == ["none", "low", "medium", "high", "xhigh", "max"]
      assert CodingAgent.efforts("claude") == []
      assert CodingAgent.efforts("claude-repl") == ["low", "medium", "high", "xhigh", "max"]
      assert CodingAgent.efforts("opencode") == []
    end

    test "immediate_delivery? is true only for the REPL backend" do
      assert CodingAgent.immediate_delivery?("claude-repl")
      refute CodingAgent.immediate_delivery?("claude")
      refute CodingAgent.immediate_delivery?("codex")
      refute CodingAgent.immediate_delivery?("opencode")
    end

    test "unknown backend fails loud" do
      assert_raise ArgumentError, ~r/unknown coding-agent backend/, fn ->
        CodingAgent.adapter("opencode")
      end
    end

    test "remote_control? is true for claude, false for codex" do
      assert CodingAgent.remote_control?("claude")
      assert CodingAgent.remote_control?("claude-repl")
      refute CodingAgent.remote_control?("codex")
    end

    test "remote_worker? is false only for direct local transports" do
      assert CodingAgent.remote_worker?("codex")
      assert CodingAgent.remote_worker?("claude")
      refute CodingAgent.remote_worker?("kimi")
      refute CodingAgent.remote_worker?("deepseek")
      refute CodingAgent.remote_worker?("openrouter")
      refute CodingAgent.remote_worker?("opencode")
    end

    test "resumable? is true for codex and claude-repl, false for headless claude" do
      # codex app-server exposes thread/resume against an on-disk rollout, and the
      # claude REPL drives the `claude` CLI directly so it can `--resume` the
      # on-disk transcript jsonl — both rejoin a prior session after a restart.
      # The headless claude app-server only rehydrates an in-memory thread map
      # (lost on restart) and exposes no disk-resume seed, so it degrades to a
      # clean start (#378/#613).
      assert CodingAgent.resumable?("codex")
      assert CodingAgent.resumable?("claude-repl")
      refute CodingAgent.resumable?("claude")
    end

    test "resumable? is false for an unknown backend" do
      refute CodingAgent.resumable?("opencode")
    end

    test "remote_control? is false for an unknown backend" do
      refute CodingAgent.remote_control?("opencode")
    end

    test "override_labels seeds backend and family tags for every backend" do
      labels = CodingAgent.override_labels()

      for label <- ~w(model:claude model:codex model:opus model:sonnet model:haiku model:sol model:terra model:luna) do
        assert label in labels
      end
    end

    test "override_labels seeds no version-specific tag" do
      refute Enum.any?(CodingAgent.override_labels(), &(&1 =~ ~r/\d/))
    end
  end

  describe "send_operator_message/2" do
    test "raises when the session has no backend instead of using the global default" do
      session = %{thread_id: "thread-missing-backend"}

      error =
        assert_raise ArgumentError, fn ->
          CodingAgent.send_operator_message(session, %{kind: :text, body: "hello agent"})
        end

      assert error.message =~ inspect(session)
      assert error.message =~ "expected a binary :backend"
    end

    test "raises when the session backend is not a binary" do
      session = %{backend: :claude, thread_id: "thread-invalid-backend"}

      error =
        assert_raise ArgumentError, fn ->
          CodingAgent.send_operator_message(session, %{kind: :text, body: "hello agent"})
        end

      assert error.message =~ inspect(session)
      assert error.message =~ "expected a binary :backend"
    end

    test "every session-routed entry point raises, not just send_operator_message/2" do
      # `adapter_for_session/1` is private, so each public caller is pinned
      # here. A new entry point that reintroduces the global-default fallback
      # on its own path would not be caught by the two tests above.
      malformed = [%{thread_id: "thread-no-backend"}, %{backend: :claude, thread_id: "thread-atom-backend"}]

      entry_points = [
        {"run_turn/4", fn session -> CodingAgent.run_turn(session, "prompt", %{}, []) end},
        {"stop_session/1", fn session -> CodingAgent.stop_session(session) end},
        {"send_operator_message/2", fn session -> CodingAgent.send_operator_message(session, %{kind: :text, body: "x"}) end}
      ]

      for {name, call} <- entry_points, session <- malformed do
        error = assert_raise ArgumentError, fn -> call.(session) end

        assert error.message =~ inspect(session), "#{name} did not name the malformed session"
        assert error.message =~ "expected a binary :backend", "#{name} did not fail loudly"
      end
    end

    test "Codex adapter writes a turn/start frame with a fresh request id" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace",
        approval_policy: "untrusted",
        turn_sandbox_policy: %{"mode" => "read-only"}
      }

      assert {:ok, request_id} =
               CodexAgent.send_operator_message(session, %{kind: :text, body: "hello agent"})

      assert is_integer(request_id) and request_id > 0

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["id"] == request_id
      assert frame["params"]["threadId"] == "thread-abc"
      assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello agent"}]
      assert frame["params"]["cwd"] == "/tmp/workspace"
      assert frame["params"]["approvalPolicy"] == "untrusted"

      close_port(port)
    end

    test "Codex adapter returns {:error, :invalid_session} for malformed session" do
      assert {:error, :invalid_session} =
               CodexAgent.send_operator_message(%{}, %{kind: :text, body: "hi"})
    end

    test "Codex adapter returns {:error, :port_closed} when port is dead" do
      port = open_cat_port()
      close_port(port)

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace",
        approval_policy: "untrusted",
        turn_sandbox_policy: %{}
      }

      assert {:error, :port_closed} =
               CodexAgent.send_operator_message(session, %{kind: :text, body: "hi"})
    end

    test "Claude adapter writes a turn/start frame with a fresh request id" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-xyz",
        workspace: "/tmp/workspace"
      }

      assert {:ok, request_id} =
               ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello claude"})

      assert is_integer(request_id) and request_id > 0

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["id"] == request_id
      assert frame["params"]["threadId"] == "thread-xyz"
      assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello claude"}]

      close_port(port)
    end

    test "Claude adapter pins the session's model into the turn/start frame" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-xyz",
        workspace: "/tmp/workspace",
        model: "opus-4-8"
      }

      assert {:ok, _request_id} =
               ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello claude"})

      frame = read_one_frame(port)
      assert frame["params"]["model"] == "opus-4-8"

      close_port(port)
    end

    test "Claude adapter returns {:error, :invalid_session} for malformed session" do
      assert {:error, :invalid_session} =
               ClaudeAgent.send_operator_message(%{}, %{kind: :text, body: "hi"})
    end
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  defp read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Jason.decode!(line)

      {^port, {:data, line}} when is_binary(line) ->
        line
        |> String.trim_trailing()
        |> Jason.decode!()
    after
      1_000 -> flunk("no frame read from port within 1s")
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  describe "Aiur.CodingAgent.Backend wiring" do
    test "every registry adapter implements the behaviour" do
      for {backend, entry} <- CodingAgent.backends() do
        behaviours =
          entry.adapter.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert Aiur.CodingAgent.Backend in behaviours,
               "adapter #{inspect(entry.adapter)} for #{inspect(backend)} " <>
                 "must declare @behaviour Aiur.CodingAgent.Backend"
      end
    end

    test "remote_transport/1 returns the declared RC transport" do
      assert CodingAgent.remote_transport("claude") == "claude-repl"
      assert CodingAgent.remote_transport("claude-repl") == "claude-repl"
      assert CodingAgent.remote_transport("codex") == "codex"
      assert CodingAgent.remote_transport("nonexistent") == "nonexistent"
    end

    test "fallback_backend/1 returns the declared spawn-failure fallback" do
      assert CodingAgent.fallback_backend("claude-repl") == "claude"
      assert CodingAgent.fallback_backend("claude") == nil
      assert CodingAgent.fallback_backend("codex") == nil
      assert CodingAgent.fallback_backend("nonexistent") == nil
    end
  end

  describe "rc_display_tail?/1" do
    test "only claude-repl feeds the RC display tailer" do
      assert CodingAgent.rc_display_tail?("claude-repl")
      refute CodingAgent.rc_display_tail?("claude")
      refute CodingAgent.rc_display_tail?("codex")
      refute CodingAgent.rc_display_tail?("mystery")
    end
  end

  describe "runtime_report/1" do
    test "claude-repl reports its pane runtime" do
      assert CodingAgent.runtime_report("claude-repl") == :repl_pane
    end

    test "headless claude reports its wrapper pid" do
      assert CodingAgent.runtime_report("claude") == :headless_wrapper
    end

    test "codex and unknown backends report nothing" do
      assert CodingAgent.runtime_report("codex") == nil
      assert CodingAgent.runtime_report("mystery") == nil
    end
  end
end
