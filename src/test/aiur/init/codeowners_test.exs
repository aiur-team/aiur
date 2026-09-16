defmodule Aiur.Init.CodeownersTest do
  use ExUnit.Case

  alias Aiur.Init.Codeowners

  setup do
    dir = Aiur.TestSupport.tmp_root!("codeowners-test")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp io(parent, answers) do
    %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end,
      input: fn label, default, _hint ->
        send(parent, {:input_label, label})
        Map.get(Map.get(answers, :input, %{}), label, default)
      end,
      select: fn label, _opts, default -> Map.get(Map.get(answers, :select, %{}), label, default) end,
      multiselect: fn label, _opts, defaults ->
        Map.get(Map.get(answers, :multiselect, %{}), label, defaults)
      end,
      confirm: fn label, default ->
        send(parent, {:confirm, label})
        Map.get(Map.get(answers, :confirm, %{}), label, default)
      end
    }
  end

  test "creates CODEOWNERS when confirm is yes and no file exists", %{dir: dir} do
    parent = self()
    answers = %{confirm: %{"Create .github/CODEOWNERS for aiur's GitHub trust checks?" => true}}
    deps = %{repo_root: fn -> dir end, github_login: fn -> nil end}

    Codeowners.setup_codeowners(io(parent, answers), deps, %{kind: "github"})

    codeowners_path = Path.join([dir, ".github", "CODEOWNERS"])
    assert File.regular?(codeowners_path)
    assert File.read!(codeowners_path) =~ "aiur uses CODEOWNERS"
  end

  test "skips CODEOWNERS when confirm is no", %{dir: dir} do
    parent = self()
    answers = %{confirm: %{"Create .github/CODEOWNERS for aiur's GitHub trust checks?" => false}}
    deps = %{repo_root: fn -> dir end, github_login: fn -> nil end}

    Codeowners.setup_codeowners(io(parent, answers), deps, %{kind: "github"})

    codeowners_path = Path.join([dir, ".github", "CODEOWNERS"])
    refute File.regular?(codeowners_path)
    messages = :erlang.process_info(self(), :messages) |> elem(1) |> Enum.filter(&match?({:puts, _}, &1)) |> Enum.map(&elem(&1, 1))
    assert Enum.any?(messages, &(&1 =~ "Skipped CODEOWNERS"))
  end

  test "adds a known operator login without another confirmation", %{dir: dir} do
    parent = self()

    deps = %{repo_root: fn -> dir end, github_login: fn -> "octocat" end}

    Codeowners.setup_codeowners(io(parent, %{}), deps, %{kind: "github", operator_account: "octocat"})

    codeowners_path = Path.join([dir, ".github", "CODEOWNERS"])
    assert File.read!(codeowners_path) =~ "@octocat"

    refute_receive {:confirm, "Add @octocat to CODEOWNERS so aiur trusts your PR/issue comments?"}
  end

  for {name, invalid} <- [{"newline", "bad\n* @intruder"}, {"comment", "bad #comment"}, {"multiple owners", "first @second"}, {"App bot", "agent[bot]"}] do
    test "CODEOWNERS human fallback rejects #{name} before writing a valid human owner", %{dir: dir} do
      invalid = unquote(invalid)
      {:ok, answers} = Agent.start_link(fn -> [invalid, "real-human"] end)
      base_io = io(self(), %{})

      input = fn _label, _default, _hint ->
        Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end)
      end

      deps = %{repo_root: fn -> dir end, github_login: fn -> nil end}
      assert :ok = Codeowners.setup_codeowners(%{base_io | input: input}, deps, %{kind: "github"})
      contents = File.read!(Path.join([dir, ".github", "CODEOWNERS"]))
      assert contents =~ "* @real-human"
      refute contents =~ "@intruder"
      refute contents =~ "@second"
      refute contents =~ "@agent[bot]"
      assert Agent.get(answers, & &1) == []
    end
  end
end
