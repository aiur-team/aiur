defmodule Aiur.Init.BotAccountTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.BotAccount

  @mode_label "Will Aiur's agents post as your own GitHub account, or as a separate bot account?"
  @bot_label "GitHub account Aiur's agents post as"
  @operator_label "Your GitHub account"

  defp io(answers \\ %{}) do
    {:ok, pid} = Agent.start_link(fn -> [] end)

    io = %{
      puts: fn message -> Agent.update(pid, &[IO.chardata_to_string(message) | &1]) end,
      input: fn label, default, _hint -> Map.get(Map.get(answers, :input, %{}), label, default) end,
      select: fn label, _options, default -> Map.get(Map.get(answers, :select, %{}), label, default) end,
      multiselect: fn _label, _options, default -> default end,
      confirm: fn _label, default -> default end
    }

    {io, pid}
  end

  defp output(pid), do: pid |> Agent.get(& &1) |> Enum.reverse() |> Enum.join("\n")
  defp deps(operator, bot), do: %{github_login: fn -> operator end, github_bot_account_default: fn -> bot end}

  test "uses the resolved operator login for own-account mode without asking for it again" do
    {io, pid} = io(%{select: %{@mode_label => "My own account (operator) — simplest; good for solo use"}})
    tracker = BotAccount.maybe_prompt(io, deps("Operator", "bot-user"), %{kind: "github", repo: "o/r"})

    assert tracker.operator_account == "operator"
    assert tracker.bot_account == "operator"
    assert tracker.identity_mode == "single_account"
    assert output(pid) =~ "mark its comments"
  end

  test "separate-account mode asks once for a distinct bot login" do
    {io, pid} = io(%{select: %{@mode_label => "A separate bot account"}, input: %{@bot_label => "Different-Bot"}})
    tracker = BotAccount.maybe_prompt(io, deps("operator", nil), %{kind: "github", repo: "o/r"})

    assert tracker.operator_account == "operator"
    assert tracker.bot_account == "different-bot"
    assert tracker.identity_mode == "separate_account"
    assert output(pid) == ""
  end

  test "re-prompts when separate mode receives the operator login" do
    {:ok, answers} = Agent.start_link(fn -> ["operator", "different-bot"] end)
    {base_io, pid} = io(%{select: %{@mode_label => "A separate bot account"}})

    io = %{
      base_io
      | input: fn _label, default, _hint ->
          Agent.get_and_update(answers, fn
            [answer | rest] -> {answer, rest}
            [] -> {default, []}
          end)
        end
    }

    tracker = BotAccount.maybe_prompt(io, deps("operator", nil), %{kind: "github", repo: "o/r"})
    assert tracker.bot_account == "different-bot"
    assert output(pid) =~ "different from your own account"
  end

  test "sanitizes an invalid detected bot default without looping" do
    {io, _pid} = io(%{select: %{@mode_label => "A separate bot account"}})
    tracker = BotAccount.maybe_prompt(io, deps("operator", "not a valid login"), %{kind: "github", repo: "o/r"})
    assert tracker.bot_account == nil
    assert tracker.identity_mode == "separate_account"
  end

  test "asks for the operator only when it could not be resolved" do
    {io, _pid} = io(%{input: %{@operator_label => "Operator"}})
    tracker = BotAccount.maybe_prompt(io, deps(nil, nil), %{kind: "github", repo: "o/r"})
    assert tracker.operator_account == "operator"
    assert tracker.bot_account == "operator"
  end

  test "passes a non-GitHub tracker through untouched" do
    {io, _pid} = io()
    tracker = %{kind: "linear", api_key: "k"}
    assert BotAccount.maybe_prompt(io, deps("ignored", nil), tracker) == tracker
  end
end
