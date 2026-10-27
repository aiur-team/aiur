defmodule VoiceConverse.TokenIssuer.HmacTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VoiceConverse.{Config, Ports}
  alias VoiceConverse.TokenIssuer.Hmac, as: Issuer

  @secret String.duplicate("s", 32)
  @t0 ~U[2026-10-21 12:00:00Z]

  # Each test owns its instance key, so installed secrets never leak between async tests.
  setup do
    instance = {__MODULE__, make_ref()}
    :ok = Issuer.put_secret(instance, @secret)
    %{inst: instance, opts: [instance: instance, now: @t0]}
  end

  defp issue!(ctx, scope \\ "converse", opts \\ []) do
    {:ok, token, expires_at} = Issuer.issue(scope, Keyword.merge(ctx.opts, opts))
    {token, expires_at}
  end

  defp at(ctx, seconds), do: [instance: ctx.inst, now: DateTime.add(@t0, seconds, :second)]

  test "a fresh token of the expected scope verifies with its claims", ctx do
    {token, expires_at} = issue!(ctx, "converse", subject: "device-7", ttl_s: 60)
    assert expires_at == ~U[2026-10-21 12:01:00Z]

    assert {:ok, %{scope: "converse", subject: "device-7", expires_at: ^expires_at}} =
             Issuer.verify(token, "converse", at(ctx, 59))
  end

  # A leaked token must stop working at its expiry, not one tick later.
  test "an expired token is rejected from its expiry instant on", ctx do
    {token, _} = issue!(ctx, "converse", ttl_s: 60)
    assert {:error, :expired} = Issuer.verify(token, "converse", at(ctx, 60))
    assert {:error, :expired} = Issuer.verify(token, "converse", at(ctx, 86_400))
  end

  # A token minted for one capability must not open another.
  test "a token minted for another scope is rejected", ctx do
    {token, _} = issue!(ctx, "briefing:read")
    assert {:error, :wrong_scope} = Issuer.verify(token, "converse", ctx.opts)
  end

  # Without the secret, rewriting the claims (wider scope, later expiry) must not verify.
  test "a token whose payload was rewritten is rejected", ctx do
    {token, _} = issue!(ctx, "briefing:read", ttl_s: 60)
    ["vct1", _payload, mac] = String.split(token, ".")

    forged =
      %{"scope" => "converse", "sub" => nil, "exp" => DateTime.to_unix(@t0) + 3_600, "nonce" => "x"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid} = Issuer.verify("vct1.#{forged}.#{mac}", "converse", at(ctx, 120))
  end

  test "a token with a flipped, truncated or missing MAC is rejected", ctx do
    {token, _} = issue!(ctx)
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
      assert {:error, :invalid} = Issuer.verify(bad, "converse", ctx.opts), "accepted #{inspect(bad)}"
    end
  end

  test "a token signed for another instance's secret is rejected", ctx do
    {token, _} = issue!(ctx)
    other = {__MODULE__, make_ref()}
    :ok = Issuer.put_secret(other, String.duplicate("o", 32))
    assert {:error, :invalid} = Issuer.verify(token, "converse", instance: other, now: @t0)
  end

  test "non-binary input is invalid rather than a crash", ctx do
    assert {:error, :invalid} = Issuer.verify(nil, "converse", ctx.opts)
    assert {:error, :invalid} = Issuer.verify(123, "converse", ctx.opts)
  end

  test "tokens stay short-lived and need a real secret", ctx do
    assert {:error, :invalid_ttl} = Issuer.issue("converse", Keyword.put(ctx.opts, :ttl_s, 3_601))
    assert {:error, :invalid_ttl} = Issuer.issue("converse", Keyword.put(ctx.opts, :ttl_s, 0))
    assert {:ok, _, _} = Issuer.issue("converse", Keyword.put(ctx.opts, :ttl_s, 3_600))
    assert {:error, :weak_secret} = Issuer.put_secret(ctx.inst, "short")
  end

  test "a secret function is read at the moment of use", ctx do
    {token, _} = issue!(ctx)
    :ok = Issuer.put_secret(ctx.inst, fn -> @secret end)
    assert {:ok, _} = Issuer.verify(token, "converse", ctx.opts)
    :ok = Issuer.put_secret(ctx.inst, fn -> "short" end)
    assert {:error, :weak_secret} = Issuer.issue("converse", ctx.opts)
  end

  test "each issue mints a distinct token", ctx do
    {a, _} = issue!(ctx)
    {b, _} = issue!(ctx)
    refute a == b
  end

  # Misconfiguration must be visible to the host, yet still fail closed and keep the token out of logs.
  test "verifying with no secret installed fails closed and warns without the token", ctx do
    {token, _} = issue!(ctx)
    bare = {__MODULE__, make_ref()}

    log =
      capture_log(fn ->
        assert {:error, :invalid} = Issuer.verify(token, "converse", instance: bare, now: @t0)
      end)

    assert log =~ "no_secret"
    refute log =~ token
  end

  # The secret never travels in call arguments (a crash report would print them); one passed there is ignored.
  test "a secret passed in call options is not used" do
    bare = [instance: {__MODULE__, make_ref()}, secret: @secret, now: @t0]
    assert {:error, :no_secret} = Issuer.issue("converse", bare)
  end

  test "verification runs under the port deadline helper", ctx do
    {token, _} = issue!(ctx)

    assert {:ok, %{scope: "converse"}} =
             Ports.call_port(Issuer, :verify, [token, "converse", ctx.opts], :token)
  end

  test "config takes a token issuer module and rejects a non-module" do
    base = [transcript_root: "/tmp/vc", credentials: Issuer, briefing_source: Issuer]
    assert {:ok, %Config{token_issuer: Issuer}} = Config.new(base ++ [token_issuer: Issuer])
    assert {:error, %{field: :token_issuer, reason: :invalid}} = Config.new(base ++ [token_issuer: "x"])
  end
end
