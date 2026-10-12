defmodule VoiceConverseTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.{Config, Ports, Redact}
  alias VoiceConverse.Testing.{FakeBriefingSource, StaticCredentials}

  @valid [transcript_root: "/tmp/vc", credentials: StaticCredentials, briefing_source: FakeBriefingSource]

  test "config without transcript_root fails with the field name" do
    assert {:error, %{field: :transcript_root}} = Config.new(Keyword.delete(@valid, :transcript_root))
  end

  test "config without credentials or briefing_source names the field" do
    assert {:error, %{field: :credentials}} = Config.new(Keyword.delete(@valid, :credentials))
    assert {:error, %{field: :briefing_source}} = Config.new(Keyword.delete(@valid, :briefing_source))
  end

  test "child_spec raises naming the field, valid config yields a supervisor spec" do
    assert_raise ArgumentError, ~r/transcript_root/, fn ->
      VoiceConverse.child_spec(Keyword.delete(@valid, :transcript_root))
    end

    assert %{id: VoiceConverse, type: :supervisor} = VoiceConverse.child_spec(@valid)
  end

  test "availability is unavailable without a provider" do
    {:ok, config} = Config.new(@valid)
    assert {:unavailable, :no_provider} = VoiceConverse.availability(config)
    assert :ok = VoiceConverse.availability(%{config | provider: {Nope, []}})
  end

  test "a port that exits is unavailable, not empty" do
    assert {:error, :unavailable} = Ports.call_port(FakeBriefingSource, :brief, [%{exit: true}], :brief)
  end

  test "a port slower than its deadline is unavailable" do
    assert {:error, :unavailable} = Ports.call_port(FakeBriefingSource, :brief, [%{sleep_ms: 500}], :brief)
  end

  test "a healthy port returns its result" do
    assert {:ok, %VoiceConverse.Briefing{}} = Ports.call_port(FakeBriefingSource, :brief, [%{}], :brief)
  end

  test "static credentials report missing providers" do
    StaticCredentials.put(%{openai: "k"})
    assert {:ok, "k"} = StaticCredentials.fetch(:openai, :connect)
    assert {:error, :missing} = StaticCredentials.fetch(:eleven, :connect)
  end

  test "default redactor masks bearer tokens, api keys and url credentials" do
    out = Redact.redact("Bearer abcdefgh12345 sk-abcdefgh1234 https://u:pw@host/x")
    refute out =~ "abcdefgh"
    refute out =~ "u:pw"
    assert out =~ "https://[redacted]@host/x"
  end

  # Regression guard (labelled): the isolation check must fail on a planted Aiur reference.
  test "the package has no aiur reference" do
    script = Path.expand("../../../../scripts/check-voice-converse-isolation.sh", __DIR__)
    pkg = Path.expand("..", __DIR__)
    assert {_, 0} = System.cmd(script, [pkg], stderr_to_stdout: true)

    tmp = Path.join(System.tmp_dir!(), "vc_iso_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.write!(Path.join(tmp, "mix.exs"), "")
    File.write!(Path.join(tmp, "lib/x.ex"), "Aiur.Foo.bar()\n")
    on_exit(fn -> File.rm_rf!(tmp) end)
    assert {_, 1} = System.cmd(script, [tmp], stderr_to_stdout: true)
  end
end
