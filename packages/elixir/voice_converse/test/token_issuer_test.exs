defmodule VoiceConverse.TokenIssuerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VoiceConverse.{Config, Ports}
  alias VoiceConverse.Testing.HmacTokenIssuer, as: Issuer

  @secret String.duplicate("s", 32)
  @t0 ~U[2026-10-21 12:00:00Z]
  @opts [secret: @secret, now: @t0]

  defp issue!(scope \\ "converse", opts \\ []) do
    {:ok, token, expires_at} = Issuer.issue(scope, Keyword.merge(@opts, opts))
    {token, expires_at}
  end

  defp at(seconds), do: [secret: @secret, now: DateTime.add(@t0, seconds, :second)]

  test "a fresh token of the expected scope verifies with its claims" do
    {token, expires_at} = issue!("converse", subject: "device-7", ttl_s: 60)
    assert expires_at == ~U[2026-10-21 12:01:00Z]

    assert {:ok, %{scope: "converse", subject: "device-7", expires_at: ^expires_at}} =
             Issuer.verify(token, "converse", at(59))
  end

  # A leaked token must stop working at its expiry, not one tick later.
  test "an expired token is rejected from its expiry instant on" do
    {token, _} = issue!("converse", ttl_s: 60)
    assert {:error, :expired} = Issuer.verify(token, "converse", at(60))
    assert {:error, :expired} = Issuer.verify(token, "converse", at(86_400))
  end

  # A token minted for one capability must not open another.
  test "a token minted for another scope is rejected" do
    {token, _} = issue!("briefing:read")
    assert {:error, :wrong_scope} = Issuer.verify(token, "converse", @opts)
  end

  # Without the secret, rewriting the claims (wider scope, later expiry) must not verify.
  test "a token whose payload was rewritten keeps failing even with a plausible body" do
    {token, _} = issue!("briefing:read", ttl_s: 60)
    ["vct1", _payload, mac] = String.split(token, ".")

    forged =
      %{"scope" => "converse", "sub" => nil, "exp" => DateTime.to_unix(@t0) + 3_600, "nonce" => "x"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid} = Issuer.verify("vct1.#{forged}.#{mac}", "converse", at(120))
  end

  test "a token with a flipped, truncated or missing MAC is rejected" do
    {token, _} = issue!()
    [prefix, payload, mac] = String.split(token, ".")
    <<first, rest::binary>> = Base.url_decode64!(mac, padding: false)
    flipped = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)

    for bad <- [
          "#{prefix}.#{payload}.#{flipped}",
          "#{prefix}.#{payload}.#{String.slice(mac, 0, 20)}",
          "#{prefix}.#{payload}",
          "#{prefix}.#{payload}.#{mac}.extra",
          "vct2.#{payload}.#{mac}",
          "",
          "not a token"
        ] do
      assert {:error, :invalid} = Issuer.verify(bad, "converse", @opts), "accepted #{inspect(bad)}"
    end
  end

  test "a token signed with another secret is rejected" do
    {token, _} = issue!()
    other = [secret: String.duplicate("o", 32), now: @t0]
    assert {:error, :invalid} = Issuer.verify(token, "converse", other)
  end

  test "a host-installed secret is used when none is passed" do
    Issuer.put_secret(@secret)
    {:ok, token, _} = Issuer.issue("converse", now: @t0)
    assert {:ok, _} = Issuer.verify(token, "converse", now: @t0)
    assert {:ok, _} = Issuer.verify(token, "converse", @opts)
  end

  test "non-binary input is invalid rather than a crash" do
    assert {:error, :invalid} = Issuer.verify(nil, "converse", @opts)
    assert {:error, :invalid} = Issuer.verify(123, "converse", @opts)
  end

  test "tokens stay short-lived and need a real secret" do
    assert {:error, :invalid_ttl} = Issuer.issue("converse", Keyword.put(@opts, :ttl_s, 3_601))
    assert {:error, :invalid_ttl} = Issuer.issue("converse", Keyword.put(@opts, :ttl_s, 0))
    assert {:ok, _, _} = Issuer.issue("converse", Keyword.put(@opts, :ttl_s, 3_600))
    assert {:error, :weak_secret} = Issuer.issue("converse", secret: "short", now: @t0)
  end

  test "each issue mints a distinct token" do
    {a, _} = issue!()
    {b, _} = issue!()
    refute a == b
  end

  test "rejections neither log nor echo the token" do
    {token, _} = issue!("briefing:read")
    tampered = token <> "A"

    log =
      capture_log(fn ->
        for t <- [token, tampered] do
          result = Issuer.verify(t, "converse", @opts)
          refute inspect(result) =~ t
        end
      end)

    refute log =~ token
  end

  test "verification runs under the port deadline helper" do
    {token, _} = issue!()

    assert {:ok, %{scope: "converse"}} =
             Ports.call_port(Issuer, :verify, [token, "converse", @opts], :token)
  end

  test "config takes a token issuer module and rejects a non-module" do
    base = [transcript_root: "/tmp/vc", credentials: Issuer, briefing_source: Issuer]
    assert {:ok, %Config{token_issuer: Issuer}} = Config.new(base ++ [token_issuer: Issuer])
    assert {:error, %{field: :token_issuer, reason: :invalid}} = Config.new(base ++ [token_issuer: "x"])
  end
end
