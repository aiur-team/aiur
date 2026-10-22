defmodule VoiceConverse.ConfigTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Config
  alias VoiceConverse.Testing.{FakeBriefingSource, StaticCredentials}

  @base [transcript_root: "/tmp/vc", credentials: StaticCredentials, briefing_source: FakeBriefingSource]
  @ready @base ++ [provider: {Nope, []}, llm: "some-model", cloud_disclosure_accepted: true]

  # The LLM and the cloud disclosure are operator decisions (E6-OQ7) with no default, so an
  # instance boots without them but no session may start until both are set.
  describe "session start without the operator's decisions" do
    test "an instance still boots, so a host without voice settings is not broken" do
      assert {:ok, %Config{llm: nil, cloud_disclosure_accepted: nil}} = Config.new(@base)
    end

    test "a missing llm is refused and named" do
      {:ok, config} = Config.new(Keyword.delete(@ready, :llm))
      assert {:error, %{field: :llm, reason: :missing}} = Config.check_session_start(config)
      assert {:unavailable, {:not_configured, :llm}} = VoiceConverse.availability(config)
    end

    test "an unanswered disclosure is refused and named" do
      {:ok, config} = Config.new(Keyword.delete(@ready, :cloud_disclosure_accepted))
      assert {:error, %{field: :cloud_disclosure_accepted, reason: :missing}} = Config.check_session_start(config)
    end

    test "a declined disclosure is refused, not treated as unanswered" do
      {:ok, config} = Config.new(Keyword.put(@ready, :cloud_disclosure_accepted, false))

      assert {:error, %{field: :cloud_disclosure_accepted, reason: :not_accepted}} =
               Config.check_session_start(config)
    end

    test "both set lets a session start" do
      {:ok, config} = Config.new(@ready)
      assert :ok = Config.check_session_start(config)
      assert :ok = VoiceConverse.availability(config)
    end

    test "a non-string llm is invalid at build time" do
      assert {:error, %{field: :llm, reason: :invalid}} = Config.new(Keyword.put(@base, :llm, :haiku))
    end
  end

  # Proposed E6-OQ6 defaults: capped at 60 minutes a day, crashed sessions count. Both are
  # operator-changeable values, not fixed rules.
  describe "daily cap" do
    test "defaults to 60 minutes with crashed sessions counted" do
      {:ok, config} = Config.new(@base)
      assert %{daily_minutes_cap: 60, count_crashed_sessions: true} = config.limits
    end

    test "the operator may change, remove or zero the cap and stop counting crashes" do
      for cap <- [30, nil, 0] do
        assert {:ok, %{limits: %{daily_minutes_cap: ^cap}}} = Config.new(@base ++ [limits: %{daily_minutes_cap: cap}])
      end

      assert {:ok, %{limits: %{count_crashed_sessions: false}}} =
               Config.new(@base ++ [limits: %{count_crashed_sessions: false}])
    end

    test "a negative cap or a non-boolean crash rule is rejected with the limit key" do
      assert {:error, %{field: :limits, key: :daily_minutes_cap}} =
               Config.new(@base ++ [limits: %{daily_minutes_cap: -1}])

      assert {:error, %{field: :limits, key: :count_crashed_sessions}} =
               Config.new(@base ++ [limits: %{count_crashed_sessions: "yes"}])
    end
  end
end
