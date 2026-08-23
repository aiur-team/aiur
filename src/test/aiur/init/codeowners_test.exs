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

  test "adds operator login to CODEOWNERS when confirmed", %{dir: dir} do
    parent = self()

    answers = %{
      confirm: %{
        "Create .github/CODEOWNERS for aiur's GitHub trust checks?" => true,
        "Add @octocat to CODEOWNERS so aiur trusts your PR/issue comments?" => true
      }
    }

    deps = %{repo_root: fn -> dir end, github_login: fn -> "octocat" end}

    Codeowners.setup_codeowners(io(parent, answers), deps, %{kind: "github"})

    codeowners_path = Path.join([dir, ".github", "CODEOWNERS"])
    assert File.read!(codeowners_path) =~ "@octocat"
  end
end
