defmodule Aiur.Events.PrCommandScannerTest do
  @moduledoc """
  `Aiur.Events.PrCommandScanner` is pure functional — no GenServer, no
  HTTP. Covers the one-off command detection (`/aiur` prefix or
  `@<bot_account>` mention), the trust gate (`author_trusted?`), the
  bot-self-loop drop, and the word-boundary mention match that must NOT
  fire on `@aiur` (a real, unrelated GitHub user) or a login that merely
  prefixes the configured bot.
  """

  use ExUnit.Case, async: true

  alias Aiur.Events.PrCommandScanner

  @prefix "/aiur"
  @bot "aiur-bot"

  defp comment(opts) do
    %{
      "id" => Keyword.get(opts, :id, 1),
      "body" => Keyword.fetch!(opts, :body),
      "user" => %{"login" => Keyword.get(opts, :login, "alice")},
      author_trusted?: Keyword.get(opts, :trusted?, true)
    }
  end

  describe "command?/3 — prefix marker" do
    test "a `/aiur …` comment by a trusted author IS a command" do
      assert PrCommandScanner.command?(
               comment(body: "/aiur fix the nil case", trusted?: true),
               @prefix,
               @bot
             )
    end

    test "leading whitespace before the prefix still matches (trimmed)" do
      assert PrCommandScanner.command?(
               comment(body: "   /aiur please rerun", trusted?: true),
               @prefix,
               @bot
             )
    end

    test "the prefix mid-body is NOT a command (must lead)" do
      refute PrCommandScanner.command?(
               comment(body: "I tried running /aiur but it failed", trusted?: true),
               @prefix,
               @bot
             )
    end
  end

  describe "command?/3 — bot mention marker" do
    test "an `@<bot>` mention by a trusted author IS a command" do
      assert PrCommandScanner.command?(
               comment(body: "hey @aiur-bot can you take a look", trusted?: true),
               @prefix,
               @bot
             )
    end

    test "the mention match is case-insensitive on the login" do
      assert PrCommandScanner.command?(
               comment(body: "ping @AIUR-BOT", trusted?: true),
               @prefix,
               @bot
             )
    end

    test "a mention of `@aiur` (a DIFFERENT login than the bot) is NOT a bot mention" do
      refute PrCommandScanner.command?(
               comment(body: "cc @aiur for visibility", trusted?: true),
               @prefix,
               "aiur-bot"
             )
    end

    test "a login that is a PREFIX of the bot login does not false-match" do
      # bot is `aiur-bot`; `@aiur` must not match it even though it is a prefix.
      refute PrCommandScanner.command?(
               comment(body: "thanks @aiur", trusted?: true),
               @prefix,
               "aiur-bot"
             )
    end

    test "a login that EXTENDS the bot login does not false-match" do
      # bot is `aiur-bot`; `@aiur-bottle` must not match the shorter bot login.
      refute PrCommandScanner.command?(
               comment(body: "ask @aiur-bottle", trusted?: true),
               @prefix,
               "aiur-bot"
             )
    end

    test "an email-like `foo@aiur-bot` tail is not a mention" do
      refute PrCommandScanner.command?(
               comment(body: "mail me at foo@aiur-bot.example", trusted?: true),
               @prefix,
               @bot
             )
    end
  end

  describe "command?/3 — trust gate" do
    test "an untrusted author's `/aiur` is ignored" do
      refute PrCommandScanner.command?(
               comment(body: "/aiur do the thing", login: "stranger", trusted?: false),
               @prefix,
               @bot
             )
    end

    test "an untrusted author's bot mention is ignored" do
      refute PrCommandScanner.command?(
               comment(body: "@aiur-bot do the thing", login: "stranger", trusted?: false),
               @prefix,
               @bot
             )
    end

    test "a string-keyed `author_trusted?` flag is honored" do
      raw = %{"id" => 9, "body" => "/aiur go", "user" => %{"login" => "bob"}, "author_trusted?" => true}
      assert PrCommandScanner.command?(raw, @prefix, @bot)
    end
  end

  describe "command?/3 — bot self-loop" do
    test "the bot's OWN `/aiur` comment is dropped even though it is trusted" do
      refute PrCommandScanner.command?(
               comment(body: "/aiur status", login: @bot, trusted?: true),
               @prefix,
               @bot
             )
    end

    test "the bot's own bot-mention comment is dropped" do
      refute PrCommandScanner.command?(
               comment(body: "as @aiur-bot I note", login: "aiur-bot", trusted?: true),
               @prefix,
               @bot
             )
    end

    test "a human mentioning the bot still passes (self-loop keys on author, not body)" do
      assert PrCommandScanner.command?(
               comment(body: "@aiur-bot please look", login: "carol", trusted?: true),
               @prefix,
               @bot
             )
    end
  end

  describe "command?/3 — negatives" do
    test "a plain comment with no marker is NOT a command" do
      refute PrCommandScanner.command?(
               comment(body: "looks good to me, thanks!", trusted?: true),
               @prefix,
               @bot
             )
    end

    test "a non-map comment is not a command" do
      refute PrCommandScanner.command?("not a map", @prefix, @bot)
    end

    test "a comment with no body is not a command" do
      refute PrCommandScanner.command?(%{"user" => %{"login" => "x"}, author_trusted?: true}, @prefix, @bot)
    end

    test "review-thread-shaped comments (author.login) resolve the author for the self-loop" do
      review = %{
        "id" => 7,
        "body" => "/aiur rerun",
        "author" => %{"login" => "aiur-bot"},
        author_trusted?: true
      }

      refute PrCommandScanner.command?(review, @prefix, @bot)
    end
  end

  describe "commands/3 — filtering a list" do
    test "returns only the trusted command comments, preserving order" do
      comments = [
        comment(id: 1, body: "/aiur first", trusted?: true),
        comment(id: 2, body: "just a note", trusted?: true),
        comment(id: 3, body: "/aiur second", login: "stranger", trusted?: false),
        comment(id: 4, body: "@aiur-bot third", trusted?: true),
        comment(id: 5, body: "/aiur fourth", login: @bot, trusted?: true)
      ]

      result = PrCommandScanner.commands(comments, @prefix, @bot)

      assert Enum.map(result, &Map.get(&1, "id")) == [1, 4]
    end

    test "an empty list yields no commands" do
      assert PrCommandScanner.commands([], @prefix, @bot) == []
    end
  end

  describe "command_body?/3 — pure body check" do
    test "a nil prefix disables prefix matching but leaves mention matching" do
      refute PrCommandScanner.command_body?("/aiur go", nil, nil)
      assert PrCommandScanner.command_body?("@aiur-bot go", nil, @bot)
    end

    test "a nil bot disables mention matching but leaves prefix matching" do
      assert PrCommandScanner.command_body?("/aiur go", @prefix, nil)
      refute PrCommandScanner.command_body?("@aiur-bot go", @prefix, nil)
    end
  end
end
