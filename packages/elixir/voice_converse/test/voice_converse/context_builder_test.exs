defmodule VoiceConverse.ContextBuilderTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Briefing, Config, ContextBuilder, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeCommandSource, FakeProvider, StaticCredentials}

  @now ~U[2026-10-26 12:00:00Z]
  @secret "ghp_this_is_a_secret_token"

  setup do
    root = transcript_root()
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "redacts every returned block before the provider and transcript", %{root: root} do
    config = config!(root, redactor: &redact_secret/1)
    start_instance(config)
    target = target(summary: @secret)

    {:ok, id} =
      VoiceConverse.start_session(config.name, target,
        client: self(),
        provider: {FakeProvider, [open_observer: self(), script: []]}
      )

    assert_receive {:fake_provider, :open_spec, %{context: context}}
    assert context =~ "[REDACTED: token]"
    refute context =~ @secret

    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    context_records = Enum.filter(records, &(&1["type"] == "context"))

    assert context_records != []
    assert Enum.any?(context_records, &(&1["text"] =~ "[REDACTED: token]"))
    refute Enum.any?(context_records, &(&1["text"] =~ @secret))
  end

  test "keeps commands and gaps when the total budget is tiny", %{root: root} do
    config = config!(root, limits: %{context_token_budget: 1})

    result =
      ContextBuilder.build(
        config,
        target(
          exit: true,
          commands: [%{id: "c1", version: 1, question: "Ship now?", options: [%{label: "Yes"}, %{label: "No"}]}]
        ),
        now: @now
      )

    assert result.text =~ "### commands (observed 2026-10-26T12:00:00Z)"
    assert result.text =~ "Options: Yes; No"
    assert result.text =~ "### gaps (observed 2026-10-26T12:00:00Z)"
    assert result.gaps == ["Briefing data unavailable"]
    assert result.tokens == div(byte_size(result.text), 4)
  end

  test "reports a missing command source as a stated gap", %{root: root} do
    config = config!(root, command_source: nil)

    result = ContextBuilder.build(config, target(), now: @now)

    assert result.gaps == ["Command data unavailable"]
    assert result.text =~ "Gaps: Command data unavailable"
  end

  test "uses the configured total context token budget", %{root: root} do
    config = config!(root, limits: %{context_token_budget: 100})
    briefing = %Briefing{extra: [%{title: "Notes", text: String.duplicate("briefing detail ", 100), observed_at: @now}]}
    target = target(briefing: briefing)

    result = ContextBuilder.build(config, target, now: @now)

    assert result.tokens <= config.limits.context_token_budget
  end

  defp config!(root, overrides) do
    {:ok, config} =
      Config.new(
        [
          name: Module.concat([VoiceConverse, "ContextBuilderTest#{System.unique_integer([:positive])}"]),
          transcript_root: root,
          credentials: StaticCredentials,
          briefing_source: FakeBriefingSource,
          command_source: FakeCommandSource,
          provider: {FakeProvider, []},
          llm: "test-model",
          cloud_disclosure_accepted: true
        ]
        |> Keyword.merge(overrides)
      )

    config
  end

  defp target(overrides \\ []) do
    briefing =
      %Briefing{
        summary: %{value: Keyword.get(overrides, :summary, "Current status"), observed_at: @now, max_age_s: nil},
        current_task: %{value: "Implementing context", observed_at: @now, max_age_s: nil},
        questions: %{value: [], observed_at: @now, max_age_s: nil}
      }

    %{
      id: "ticket-4126",
      title: "Context ticket",
      briefing: Keyword.get(overrides, :briefing, briefing),
      commands: Keyword.get(overrides, :commands, []),
      exit: Keyword.get(overrides, :exit, false)
    }
  end

  defp transcript_root do
    root = Path.join(System.tmp_dir!(), "voice_converse_context_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    root
  end

  defp start_instance(config), do: start_supervised!(VoiceConverse.child_spec(config))
  defp redact_secret(text), do: String.replace(text, @secret, "[REDACTED: token]")
end
