defmodule Aiur.Config.SchemaValuesTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.{Polling, StringOrMap}

  describe "StringOrMap" do
    test "casts strings and maps, rejects everything else" do
      assert {:ok, "untrusted"} = StringOrMap.cast("untrusted")

      assert {:ok, %{"type" => "workspaceWrite"}} =
               StringOrMap.cast(%{"type" => "workspaceWrite"})

      assert :error = StringOrMap.cast(123)
      assert :error = StringOrMap.cast([:list])
      assert :error = StringOrMap.cast(nil)
    end

    test "approval_policy defaults to the string 'untrusted' not a map" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.agent.codex.approval_policy == "untrusted"
      assert is_binary(settings.agent.codex.approval_policy)
    end
  end

  # FI-CFG-031: Polling raises ArgumentError on legacy interval_ms key, not a changeset error
  describe "Polling interval_ms rejection" do
    test "raises ArgumentError on interval_ms string key" do
      assert_raise ArgumentError, ~r/interval_ms is no longer supported/, fn ->
        Schema.parse(%{"polling" => %{"interval_ms" => 1000}})
      end
    end

    test "raises ArgumentError on interval_ms atom key" do
      assert_raise ArgumentError, ~r/interval_ms is no longer supported/, fn ->
        Polling.changeset(%Polling{}, %{interval_ms: 1000})
      end
    end

    test "parses interval_seconds normally" do
      {:ok, settings} = Schema.parse(%{"polling" => %{"interval_seconds" => 60}})
      assert settings.polling.interval_seconds == 60
    end

    # The poll loop's GitHub spend is fixed cost that scales as 1/interval, so
    # the default is what most fleets actually pay. At 30s it exceeded GitHub's
    # whole 5,000 point/hour budget on its own. An operator who configures a
    # tighter interval still gets it; only the unset case is widened.
    test "interval_seconds defaults to the widened 120s" do
      {:ok, unset} = Schema.parse(%{})
      assert unset.polling.interval_seconds == 120

      {:ok, empty_section} = Schema.parse(%{"polling" => %{}})
      assert empty_section.polling.interval_seconds == 120

      {:ok, tightened} = Schema.parse(%{"polling" => %{"interval_seconds" => 15}})
      assert tightened.polling.interval_seconds == 15
    end

    test "idle_widen_factor defaults to 5 and can only widen polling" do
      {:ok, unset} = Schema.parse(%{})
      assert unset.polling.idle_widen_factor == 5.0

      {:ok, configured} = Schema.parse(%{"polling" => %{"idle_widen_factor" => 8}})
      assert configured.polling.idle_widen_factor == 8.0

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"idle_widen_factor" => 0.5}})

      assert message =~ "polling.idle_widen_factor"
      assert message =~ "between 1.0 and 100.0"

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"idle_widen_factor" => 1.0e100}})

      assert message =~ "polling.idle_widen_factor"
    end

    # Measured: the provider usage endpoint serves roughly one request per two
    # minutes. Below that the excess is rejected and the meters quietly stop
    # updating, so the floor is enforced rather than merely documented.
    test "usage_interval_seconds is floored at the endpoint's real limit" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"usage_interval_seconds" => 60}})

      assert message =~ "polling.usage_interval_seconds"
      assert message =~ "at least 120 seconds"

      assert {:error, _} = Schema.parse(%{"polling" => %{"usage_interval_seconds" => 119}})

      {:ok, settings} = Schema.parse(%{"polling" => %{"usage_interval_seconds" => 120}})
      assert settings.polling.usage_interval_seconds == 120
    end

    # Per-class cadences (#2309): `polling.intervals` names a class and
    # overrides `interval_seconds` for that class only. The map is optional and
    # empty by default, so existing configs keep today's single-interval
    # behaviour.
    test "intervals defaults to an empty map" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.polling.intervals == %{}
    end

    test "intervals accepts a per-class map of positive seconds" do
      {:ok, settings} =
        Schema.parse(%{
          "polling" => %{
            "interval_seconds" => 120,
            "intervals" => %{"dispatch" => 120, "planning" => 600, "review" => 300}
          }
        })

      assert settings.polling.intervals == %{"dispatch" => 120, "planning" => 600, "review" => 300}
    end

    test "intervals accepts 0 as the on-demand (no timer) value" do
      {:ok, settings} =
        Schema.parse(%{
          "polling" => %{"intervals" => %{"planning" => 0, "firehose" => 0}}
        })

      assert settings.polling.intervals == %{"planning" => 0, "firehose" => 0}
    end

    test "intervals rejects an unknown class" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"intervals" => %{"plannning" => 600}}})

      assert message =~ "unknown poll class"
      assert message =~ "planning"
    end

    test "intervals rejects a negative value" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"intervals" => %{"planning" => -1}}})

      assert message =~ "planning"
      assert message =~ "non-negative"
    end

    # Review feedback #2309 (finding 1): `dispatch` now binds the tick, so `0`
    # there is not an on-demand value — it would stop the scheduler (an
    # immediate-reschedule busy loop). The schema rejects it outright rather
    # than silently falling back, so the dead-config failure mode is impossible.
    test "intervals rejects dispatch: 0 (the dispatch tick must always run)" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"polling" => %{"intervals" => %{"dispatch" => 0}}})

      assert message =~ "dispatch"
      assert message =~ "positive"

      {:ok, settings} = Schema.parse(%{"polling" => %{"intervals" => %{"dispatch" => 60}}})
      assert settings.polling.intervals == %{"dispatch" => 60}
    end

    test "usage_interval_seconds defaults above the floor" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.polling.usage_interval_seconds == 300
    end
  end

  # FI-CFG-029 / FI-CFG-035: $ENV token grammar
  describe "env reference grammar" do
    test "$NAME with a valid identifier resolves from the environment" do
      System.put_env("AIUR_TEST_CFG_VAR_123", "/tmp/resolved-root")
      on_exit(fn -> System.delete_env("AIUR_TEST_CFG_VAR_123") end)

      {:ok, settings} =
        Schema.parse(%{"workspace" => %{"root" => "$AIUR_TEST_CFG_VAR_123"}})

      assert settings.workspace.root == "/tmp/resolved-root"
    end

    test "invalid $NAME (starts with digit) passes through as a literal" do
      {:ok, settings} =
        Schema.parse(%{"workspace" => %{"root" => "$123INVALID"}})

      assert settings.workspace.root == "$123INVALID"
    end

    test "invalid $NAME (contains hyphen) passes through as a literal" do
      {:ok, settings} =
        Schema.parse(%{"workspace" => %{"root" => "$MY-VAR"}})

      assert settings.workspace.root == "$MY-VAR"
    end
  end

  # FI-CFG-025: secret resolution – env set / empty-string env → nil / missing env → fallback
  describe "secret resolution" do
    test "linear api_key set in config overrides absent env var" do
      System.delete_env("LINEAR_API_KEY")

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "from-config"}}})

      assert settings.tracker.linear.api_key == "from-config"
    end

    test "linear api_key as $ENV_REF resolves from environment" do
      System.put_env("AIUR_TEST_LINEAR_KEY", "env-token")
      on_exit(fn -> System.delete_env("AIUR_TEST_LINEAR_KEY") end)

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "$AIUR_TEST_LINEAR_KEY"}}})

      assert settings.tracker.linear.api_key == "env-token"
    end

    test "empty-string env var resolves to nil, not the empty string" do
      System.put_env("AIUR_TEST_LINEAR_KEY", "")
      on_exit(fn -> System.delete_env("AIUR_TEST_LINEAR_KEY") end)

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "$AIUR_TEST_LINEAR_KEY"}}})

      assert settings.tracker.linear.api_key == nil
    end

    test "missing env var for $REF falls back to LINEAR_API_KEY env fallback" do
      System.delete_env("AIUR_NONEXISTENT_VAR")
      previous = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "fallback-value")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)

      {:ok, settings} =
        Schema.parse(%{"tracker" => %{"linear" => %{"api_key" => "$AIUR_NONEXISTENT_VAR"}}})

      # $AIUR_NONEXISTENT_VAR is missing → falls back to LINEAR_API_KEY env
      assert settings.tracker.linear.api_key == "fallback-value"
    end
  end

  describe "elevenlabs voice-input section" do
    setup do
      previous = System.get_env("ELEVENLABS_API_KEY")
      System.delete_env("ELEVENLABS_API_KEY")
      on_exit(fn -> restore_env("ELEVENLABS_API_KEY", previous) end)
      :ok
    end

    test "defaults to no key and the ISO-639-3 English language code when the section is absent" do
      assert {:ok, settings} = Schema.parse(%{})

      assert settings.elevenlabs.api_key == nil
      assert settings.elevenlabs.enabled == true
      assert settings.elevenlabs.language_code == "eng"
      assert settings.elevenlabs.voice_id == nil
    end

    test "parses an explicit section" do
      assert {:ok, settings} =
               Schema.parse(%{"elevenlabs" => %{"api_key" => "from-config", "language_code" => "spa", "voice_id" => "voice-123"}})

      assert settings.elevenlabs.api_key == "from-config"
      assert settings.elevenlabs.enabled == true
      assert settings.elevenlabs.language_code == "spa"
      assert settings.elevenlabs.voice_id == "voice-123"
    end

    test "$ELEVENLABS_API_KEY resolves from the environment" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} = Schema.parse(%{"elevenlabs" => %{"api_key" => "$ELEVENLABS_API_KEY"}})

      assert settings.elevenlabs.api_key == "env-token"
    end

    test "an explicit config value wins over the ELEVENLABS_API_KEY env var" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} = Schema.parse(%{"elevenlabs" => %{"api_key" => "from-config"}})

      assert settings.elevenlabs.api_key == "from-config"
    end

    test "the env var supplies the key when the section omits it" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} = Schema.parse(%{"elevenlabs" => %{"language_code" => "eng"}})

      assert settings.elevenlabs.api_key == "env-token"
    end

    test "explicit disablement suppresses configured and fallback credentials" do
      System.put_env("ELEVENLABS_API_KEY", "env-token")

      assert {:ok, settings} =
               Schema.parse(%{"elevenlabs" => %{"enabled" => false, "api_key" => "from-config"}})

      assert settings.elevenlabs.enabled == false
      assert settings.elevenlabs.api_key == nil

      assert {:ok, fallback_settings} = Schema.parse(%{"elevenlabs" => %{"enabled" => false}})
      assert fallback_settings.elevenlabs.api_key == nil
    end
  end

  # FI-CFG-035: workspace.root $VAR and empty → tmp default

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
