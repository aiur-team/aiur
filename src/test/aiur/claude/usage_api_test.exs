defmodule Aiur.Claude.UsageApiTest do
  # Shares a :persistent_term cache key, so keep serial and reset per test.
  use ExUnit.Case, async: false

  alias Aiur.Claude.UsageApi

  setup do
    UsageApi.reset_cache()
    on_exit(&UsageApi.reset_cache/0)
    :ok
  end

  defp write_credentials(dir, contents) do
    path = Path.join(dir, ".credentials.json")
    File.write!(path, contents)
    path
  end

  defp oauth_json(fields) do
    Jason.encode!(%{"claudeAiOauth" => fields})
  end

  defp tmp_subdir(prefix) do
    dir =
      Aiur.TestSupport.tmp_root!("usage_api_test_#{prefix}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "select_window/1" do
    test "picks the worst-consumed window across all reported windows" do
      body = %{
        "five_hour" => %{"utilization" => 10, "resets_at" => "2026-07-30T12:00:00Z"},
        "seven_day" => %{"utilization" => 42, "resets_at" => "2026-08-01T00:00:00Z"},
        "seven_day_opus" => %{"utilization" => 7}
      }

      assert {:ok, reading} = UsageApi.select_window(body)
      assert reading.used_percent == 42
      assert reading.window == "seven_day"
      assert reading.resets_at == ~U[2026-08-01 00:00:00Z]
    end

    test "clamps utilization above 100 to 100" do
      body = %{"five_hour" => %{"utilization" => 137}}
      assert {:ok, %{used_percent: 100, window: "five_hour"}} = UsageApi.select_window(body)
    end

    test "ignores windows the endpoint does not report" do
      body = %{"five_hour" => %{"utilization" => 5}, "unknown_window" => %{"utilization" => 99}}
      assert {:ok, %{used_percent: 5, window: "five_hour"}} = UsageApi.select_window(body)
    end

    test "skips windows with non-numeric or negative utilization" do
      body = %{
        "five_hour" => %{"utilization" => "nope"},
        "seven_day" => %{"utilization" => -3},
        "seven_day_sonnet" => %{"utilization" => 9}
      }

      assert {:ok, %{used_percent: 9, window: "seven_day_sonnet"}} = UsageApi.select_window(body)
    end

    test "returns nil reset when resets_at is missing or malformed" do
      body = %{"five_hour" => %{"utilization" => 5, "resets_at" => "not-a-date"}}
      assert {:ok, %{resets_at: nil}} = UsageApi.select_window(body)
    end

    test "no usable window yields :no_utilization" do
      assert {:error, :no_utilization} = UsageApi.select_window(%{})
      assert {:error, :no_utilization} = UsageApi.select_window(%{"five_hour" => %{}})
    end

    test "a non-map body yields :no_utilization" do
      assert {:error, :no_utilization} = UsageApi.select_window("bogus")
    end

    # The five-hour session window resets constantly, so a meter that shows only
    # it is nearly useless for planning. Every reported window is carried, with
    # the weekly ones ahead of the session window by priority.
    test "carries every reported window with the weekly windows first" do
      body = %{
        "five_hour" => %{"utilization" => 21, "resets_at" => "2026-09-01T18:00:00Z"},
        "seven_day" => %{"utilization" => 5, "resets_at" => "2026-09-03T18:00:00Z"},
        "seven_day_opus" => %{"utilization" => 2}
      }

      assert {:ok, %{windows: windows}} = UsageApi.select_window(body)

      assert Enum.map(windows, & &1.window) == ["seven_day", "seven_day_opus", "five_hour"]
      assert Enum.map(windows, & &1.priority) == [0, 1, 3]

      by_window = Map.new(windows, &{&1.window, &1})
      assert by_window["seven_day"].used_percent == 5
      assert by_window["seven_day"].resets_at == ~U[2026-09-03 18:00:00Z]
      assert by_window["seven_day"].scope == :weekly
      assert by_window["seven_day"].coverage == :supported
      assert by_window["five_hour"].scope == :session
    end

    # A weekly window the endpoint omits must still reach the surface saying so.
    # Dropping it would leave a card showing only the session bar, which reads
    # as a healthy weekly standing that was never observed.
    test "an unreported weekly window is carried with no percentage" do
      assert {:ok, %{windows: windows}} = UsageApi.select_window(%{"five_hour" => %{"utilization" => 21}})

      weekly = Enum.find(windows, &(&1.window == "seven_day"))
      assert weekly.coverage == :empty_supported
      assert weekly.used_percent == nil
      assert weekly.resets_at == nil
    end

    test "an unreported optional window is not invented" do
      assert {:ok, %{windows: windows}} = UsageApi.select_window(%{"five_hour" => %{"utilization" => 21}})
      refute Enum.any?(windows, &(&1.window == "seven_day_opus"))
    end
  end

  describe "access_token/1" do
    @tag :tmp_dir
    test "returns the token from a valid credentials file", %{tmp_dir: dir} do
      path = write_credentials(dir, oauth_json(%{"accessToken" => "sk-live-abc"}))
      assert {:ok, "sk-live-abc"} = UsageApi.access_token(credentials_path: path)
    end

    test "missing file yields :no_credentials" do
      assert {:error, :no_credentials} =
               UsageApi.access_token(credentials_path: "/no/such/file.json")
    end

    @tag :tmp_dir
    test "malformed JSON yields :malformed_credentials", %{tmp_dir: dir} do
      path = write_credentials(dir, "{not json")
      assert {:error, :malformed_credentials} = UsageApi.access_token(credentials_path: path)
    end

    @tag :tmp_dir
    test "no oauth section yields :no_oauth_token", %{tmp_dir: dir} do
      path = write_credentials(dir, Jason.encode!(%{"somethingElse" => true}))
      assert {:error, :no_oauth_token} = UsageApi.access_token(credentials_path: path)
    end

    @tag :tmp_dir
    test "an empty token string is rejected as no oauth token", %{tmp_dir: dir} do
      # An empty accessToken is "not signed in", not "token lapsed": it must
      # yield :no_oauth_token so the surface can name the honest state.
      path = write_credentials(dir, oauth_json(%{"accessToken" => ""}))
      assert {:error, :no_oauth_token} = UsageApi.access_token(credentials_path: path)
    end

    @tag :tmp_dir
    test "a zero expiry is rejected as expired", %{tmp_dir: dir} do
      # A signed-out Claude Code writes `expiresAt: 0` alongside a token; it
      # must read as already expired rather than "no expiry".
      path = write_credentials(dir, oauth_json(%{"accessToken" => "sk-zero", "expiresAt" => 0}))
      assert {:error, :token_expired} = UsageApi.access_token(credentials_path: path)
    end

    @tag :tmp_dir
    test "expired token is rejected without a request", %{tmp_dir: dir} do
      path =
        write_credentials(
          dir,
          oauth_json(%{"accessToken" => "sk-old", "expiresAt" => 1_000})
        )

      assert {:error, :token_expired} =
               UsageApi.access_token(credentials_path: path, now_ms: 2_000)
    end

    @tag :tmp_dir
    test "an unexpired token with a future expiry is accepted", %{tmp_dir: dir} do
      path =
        write_credentials(
          dir,
          oauth_json(%{"accessToken" => "sk-fresh", "expiresAt" => 10_000})
        )

      assert {:ok, "sk-fresh"} =
               UsageApi.access_token(credentials_path: path, now_ms: 5_000)
    end
  end

  describe "default_credentials_path/0" do
    test "points at ~/.claude/.credentials.json" do
      assert String.ends_with?(UsageApi.default_credentials_path(), "/.claude/.credentials.json")
    end
  end

  describe "fetch/1 request handling" do
    setup do
      dir = tmp_subdir("req")
      path = write_credentials(dir, oauth_json(%{"accessToken" => "sk-test"}))
      {:ok, credentials_path: path}
    end

    test "a 200 with usage returns the worst window reading", %{credentials_path: path} do
      request_fun = fn "sk-test" ->
        {:ok, %{status: 200, body: %{"five_hour" => %{"utilization" => 61}}}}
      end

      assert {:ok, %{used_percent: 61, window: "five_hour"}} =
               UsageApi.fetch(credentials_path: path, request_fun: request_fun)
    end

    test "a 429 yields :rate_limited", %{credentials_path: path} do
      request_fun = fn _token -> {:ok, %{status: 429}} end

      assert {:error, :rate_limited} =
               UsageApi.fetch(credentials_path: path, request_fun: request_fun)
    end

    test "401/403 yield :unauthorized", %{credentials_path: path} do
      for status <- [401, 403] do
        UsageApi.reset_cache()
        request_fun = fn _token -> {:ok, %{status: status}} end

        assert {:error, :unauthorized} =
                 UsageApi.fetch(credentials_path: path, request_fun: request_fun)
      end
    end

    test "an unexpected status yields :request_failed", %{credentials_path: path} do
      request_fun = fn _token -> {:ok, %{status: 500}} end

      assert {:error, :request_failed} =
               UsageApi.fetch(credentials_path: path, request_fun: request_fun)
    end

    test "a transport error yields :request_failed", %{credentials_path: path} do
      request_fun = fn _token -> {:error, :econnrefused} end

      assert {:error, :request_failed} =
               UsageApi.fetch(credentials_path: path, request_fun: request_fun)
    end

    test "a raising request_fun is caught as :request_failed", %{credentials_path: path} do
      request_fun = fn _token -> raise "boom" end

      assert {:error, :request_failed} =
               UsageApi.fetch(credentials_path: path, request_fun: request_fun)
    end

    test "missing credentials short-circuit before any request" do
      request_fun = fn _token -> flunk("request should not run without credentials") end

      assert {:error, :no_credentials} =
               UsageApi.fetch(credentials_path: "/no/such.json", request_fun: request_fun)
    end
  end

  describe "fetch/1 caching" do
    setup do
      dir = tmp_subdir("cache")
      path = write_credentials(dir, oauth_json(%{"accessToken" => "sk-test"}))
      {:ok, credentials_path: path}
    end

    test "a fresh good reading is served from cache without re-requesting", %{
      credentials_path: path
    } do
      counter = :counters.new(1, [])

      request_fun = fn _token ->
        :counters.add(counter, 1, 1)
        {:ok, %{status: 200, body: %{"five_hour" => %{"utilization" => 33}}}}
      end

      opts = [credentials_path: path, request_fun: request_fun, ttl_ms: 60_000, now_ms: 1_000]

      assert {:ok, %{used_percent: 33}} = UsageApi.fetch(opts)
      assert {:ok, %{used_percent: 33}} = UsageApi.fetch(Keyword.put(opts, :now_ms, 2_000))
      assert :counters.get(counter, 1) == 1
    end

    test "the cache expires after its TTL and re-requests", %{credentials_path: path} do
      counter = :counters.new(1, [])

      request_fun = fn _token ->
        :counters.add(counter, 1, 1)
        {:ok, %{status: 200, body: %{"five_hour" => %{"utilization" => 33}}}}
      end

      assert {:ok, _} =
               UsageApi.fetch(
                 credentials_path: path,
                 request_fun: request_fun,
                 ttl_ms: 1_000,
                 now_ms: 1_000
               )

      assert {:ok, _} =
               UsageApi.fetch(
                 credentials_path: path,
                 request_fun: request_fun,
                 ttl_ms: 1_000,
                 now_ms: 5_000
               )

      assert :counters.get(counter, 1) == 2
    end

    test "after a 429 the last good reading is kept and requests pause", %{credentials_path: path} do
      good = fn _token -> {:ok, %{status: 200, body: %{"five_hour" => %{"utilization" => 50}}}} end
      limited = fn _token -> {:ok, %{status: 429}} end

      assert {:ok, %{used_percent: 50}} =
               UsageApi.fetch(credentials_path: path, request_fun: good, ttl_ms: 1, now_ms: 1_000)

      # TTL has elapsed so a request happens; it 429s but the good value is retained.
      assert {:error, :rate_limited} =
               UsageApi.fetch(credentials_path: path, request_fun: limited, ttl_ms: 1, now_ms: 5_000)

      # During the backoff window, the retained good reading is served without a request.
      no_request = fn _token -> flunk("must not request during 429 backoff") end

      assert {:ok, %{used_percent: 50}} =
               UsageApi.fetch(credentials_path: path, request_fun: no_request, now_ms: 6_000)
    end

    test "errors other than 429 are not cached", %{credentials_path: path} do
      counter = :counters.new(1, [])

      request_fun = fn _token ->
        :counters.add(counter, 1, 1)
        {:ok, %{status: 500}}
      end

      opts = [credentials_path: path, request_fun: request_fun, ttl_ms: 60_000]

      assert {:error, :request_failed} = UsageApi.fetch(opts)
      assert {:error, :request_failed} = UsageApi.fetch(opts)
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "reset_cache/0" do
    @tag :tmp_dir
    test "forces the next fetch to re-request", %{tmp_dir: dir} do
      path = write_credentials(dir, oauth_json(%{"accessToken" => "sk-test"}))
      counter = :counters.new(1, [])

      request_fun = fn _token ->
        :counters.add(counter, 1, 1)
        {:ok, %{status: 200, body: %{"five_hour" => %{"utilization" => 12}}}}
      end

      opts = [credentials_path: path, request_fun: request_fun, ttl_ms: 60_000]

      assert {:ok, _} = UsageApi.fetch(opts)
      assert :ok = UsageApi.reset_cache()
      assert {:ok, _} = UsageApi.fetch(opts)
      assert :counters.get(counter, 1) == 2
    end
  end
end
