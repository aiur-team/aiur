defmodule Aiur.Init.BotAccountTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.BotAccount

  # A scripted io whose `input` returns the next queued answer (Agent-backed so
  # a re-prompt sees the following answer), records puts, and never selects.
  defp io(answers) do
    {:ok, pid} = Agent.start_link(fn -> {answers, []} end)

    io = %{
      puts: fn message ->
        Agent.update(pid, fn {a, puts} -> {a, [IO.chardata_to_string(message) | puts]} end)
        :ok
      end,
      input: fn _label, default, _hint ->
        Agent.get_and_update(pid, fn
          {[next | rest], puts} -> {next, {rest, puts}}
          {[], puts} -> {default, {[], puts}}
        end)
      end,
      select: fn _l, _o, d -> d end,
      multiselect: fn _l, _o, d -> d end,
      confirm: fn _l, d -> d end
    }

    {io, pid}
  end

  defp puts_output(pid), do: pid |> Agent.get(fn {_a, puts} -> puts end) |> Enum.reverse() |> Enum.join("\n")

  defp deps(default), do: %{github_bot_account_default: fn -> default end}

  test "accepts the token's detected login as the default" do
    {io, _pid} = io([])
    tracker = BotAccount.maybe_prompt(io, deps("its-applekid"), %{kind: "github", repo: "o/r"})
    assert tracker.bot_account == "its-applekid"
  end

  test "normalizes a custom login (strips @, lowercases)" do
    {io, _pid} = io(["@Its-AppleKid"])
    tracker = BotAccount.maybe_prompt(io, deps("octocat"), %{kind: "github", repo: "o/r"})
    assert tracker.bot_account == "its-applekid"
  end

  test "a blank answer skips bot_account and explains the consequence" do
    {io, pid} = io([""])
    tracker = BotAccount.maybe_prompt(io, deps(nil), %{kind: "github", repo: "o/r"})
    assert tracker.bot_account == nil
    assert Map.has_key?(tracker, :bot_account)
    assert puts_output(pid) =~ "Skipped bot_account"
  end

  test "a malformed login re-prompts until a valid login is given" do
    {io, pid} = io(["not a login!", "valid-bot"])
    tracker = BotAccount.maybe_prompt(io, deps(nil), %{kind: "github", repo: "o/r"})
    assert tracker.bot_account == "valid-bot"
    assert puts_output(pid) =~ "valid GitHub login"
  end

  test "explains the credential-vs-identity distinction and the dedicated-account recommendation" do
    {io, pid} = io([""])
    BotAccount.maybe_prompt(io, deps(nil), %{kind: "github", repo: "o/r"})
    output = puts_output(pid)
    assert output =~ "GITHUB_TOKEN"
    assert output =~ "bot_account"
    assert output =~ "credential"
    assert output =~ ~r/dedicated bot account/i
    assert output =~ "#1151"
  end

  test "passes a non-github tracker through untouched" do
    {io, _pid} = io([])
    tracker = %{kind: "linear", api_key: "k"}
    assert BotAccount.maybe_prompt(io, deps("ignored"), tracker) == tracker
  end
end
