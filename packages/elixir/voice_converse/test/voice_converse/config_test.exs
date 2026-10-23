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

    test "a blank or whitespace-only llm counts as missing, not as a choice" do
      for blank <- ["", "   "] do
        {:ok, config} = Config.new(Keyword.put(@ready, :llm, blank))
        assert {:error, %{field: :llm, reason: :missing}} = Config.check_session_start(config)
      end
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

  # Proposed E6-OQ6 default: capped at 60 minutes a day, operator-changeable. Crashed sessions
  # always count toward the cap; that rule is not a setting.
  describe "daily cap" do
    test "defaults to 60 minutes, with no setting to stop counting crashed sessions" do
      {:ok, config} = Config.new(@base)
      assert %{daily_minutes_cap: 60} = config.limits
      refute Map.has_key?(config.limits, :count_crashed_sessions)
    end

    test "the operator may change, remove or zero the cap" do
      for cap <- [30, nil, 0] do
        assert {:ok, %{limits: %{daily_minutes_cap: ^cap}}} = Config.new(@base ++ [limits: %{daily_minutes_cap: cap}])
      end
    end

    test "a negative cap is rejected with the limit key" do
      assert {:error, %{field: :limits, key: :daily_minutes_cap}} =
               Config.new(@base ++ [limits: %{daily_minutes_cap: -1}])
    end
  end
end
