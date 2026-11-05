defmodule Aiur.Commands.ScopeTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.Scope

  @secret String.duplicate("s", 64)
  @now ~U[2026-11-05 12:00:00Z]

  test "minting and verifying round-trips the subject and ticket set" do
    assert {:ok, %{token: token, scope: minted}} =
             Scope.mint("player-7", ["42", "43"], secret: @secret, now: @now, expires_in: 600)

    assert minted.subject == "player-7"
    assert minted.tickets == ["42", "43"]
    assert minted.expires_at == DateTime.add(@now, 600, :second)

    assert {:ok, scope} = Scope.verify(token, secret: @secret, now: @now)
    assert scope.subject == "player-7"
    assert scope.tickets == ["42", "43"]
    assert MapSet.member?(scope.ticket_set, "42")
    refute MapSet.member?(scope.ticket_set, "99")
  end

  test "the grant is opaque and does not carry Command data" do
    assert {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: @secret, now: @now)
    refute token =~ "42"
    refute token =~ "player-7"
  end

  test "a tampered token fails verification" do
    assert {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: @secret, now: @now)
    [prefix, _body, signature] = String.split(token, ".")

    tampered_body = Base.url_encode64(Jason.encode!(%{"v" => 1, "sub" => "player-7", "tickets" => ["9"], "iat" => 1, "exp" => 99_999}), padding: false)

    assert {:error, :invalid_signature} = Scope.verify(Enum.join([prefix, tampered_body, signature], "."), secret: @secret, now: @now)
    assert {:error, :malformed} = Scope.verify("nonsense", secret: @secret, now: @now)
    assert {:error, :malformed} = Scope.verify(nil, secret: @secret, now: @now)
  end

  test "a grant signed with another secret is rejected" do
    assert {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: @secret, now: @now)

    other_secret = String.duplicate("x", 64)
    assert {:error, :invalid_signature} = Scope.verify(token, secret: other_secret, now: @now)
  end

  test "an expired grant is rejected even when the signature is valid" do
    assert {:ok, %{token: token}} = Scope.mint("player-7", ["42"], secret: @secret, now: @now, expires_in: 60)

    assert {:error, :expired} = Scope.verify(token, secret: @secret, now: DateTime.add(@now, 61, :second))
  end

  test "minting rejects a missing subject, empty ticket set, and unusable secret" do
    assert {:error, :invalid_scope} = Scope.mint("", ["42"], secret: @secret)
    assert {:error, :invalid_scope} = Scope.mint("player-7", [], secret: @secret)
    assert {:error, :invalid_scope} = Scope.mint("player-7", ["42"], secret: "short")
    assert {:error, :invalid_scope} = Scope.mint("player-7", ["42"], secret: @secret, expires_in: 0)
    assert {:error, :invalid_scope} = Scope.mint("player-7", ["42"], secret: @secret, expires_in: 90_000)
    assert {:error, :invalid_scope} = Scope.mint("player\n7", ["42"], secret: @secret)
  end

  test "duplicate tickets are collapsed" do
    assert {:ok, %{scope: scope}} = Scope.mint("player-7", ["42", "42"], secret: @secret)
    assert scope.tickets == ["42"]
  end

  test "a label scope round-trips normalized labels" do
    assert {:ok, %{token: token, scope: minted}} =
             Scope.mint("player-7", [], secret: @secret, now: @now, labels: ["Game:Chess", "game:chess"])

    assert minted.tickets == []
    assert minted.labels == ["game:chess"]

    assert {:ok, scope} = Scope.verify(token, secret: @secret, now: @now)
    assert scope.labels == ["game:chess"]
    assert MapSet.member?(scope.label_set, "game:chess")
    refute MapSet.member?(scope.label_set, "game:checkers")
  end

  test "minting downcases the ticket identifiers so authorization cannot miss on case" do
    assert {:ok, %{token: token, scope: minted}} = Scope.mint("player-7", [" AbC "], secret: @secret, now: @now)
    assert minted.tickets == ["abc"]
    assert MapSet.member?(minted.ticket_set, "abc")

    assert {:ok, scope} = Scope.verify(token, secret: @secret, now: @now)
    assert scope.tickets == ["abc"]
  end

  test "minting rejects a malformed label and a grant that authorizes nothing" do
    assert {:error, :invalid_scope} = Scope.mint("player-7", [], secret: @secret, labels: ["game chess"])
    assert {:error, :invalid_scope} = Scope.mint("player-7", [], secret: @secret, labels: ["nocolon"])
    assert {:error, :invalid_scope} = Scope.mint("player-7", [], secret: @secret)
    assert {:error, :invalid_scope} = Scope.mint("player-7", [], secret: @secret, labels: [])
  end

  test "to_public describes the scope without exposing the token" do
    assert {:ok, %{scope: scope}} = Scope.mint("player-7", ["42"], secret: @secret)

    assert Scope.to_public(scope) == %{
             "kind" => "tickets",
             "label" => "Ticket-scoped Commands",
             "tickets" => ["42"]
           }
  end
end
