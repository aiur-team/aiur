defmodule Aiur.Init.RuntimeTest do
  use ExUnit.Case, async: false

  alias Aiur.Init.Templates
  alias Aiur.Init.Runtime
  alias Aiur.RepoBase

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-init-runtime-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "load_config returns config for a written config file", %{dir: dir} do
    path = Path.join(dir, ".aiurconfig")
    File.write!(path, "tracker:\n  kind: memory\n")

    assert {:ok, %{"tracker" => %{"kind" => "memory"}}} = Runtime.load_config(path)
  end

  test "load_config returns an error for a missing config", %{dir: dir} do
    assert {:error, _reason} = Runtime.load_config(Path.join(dir, "missing"))
  end

  test "detect_toolchain returns a Detect.result for a scratch dir", %{dir: dir} do
    result = File.cd!(dir, fn -> Runtime.detect_toolchain() end)

    assert match_result_type(result)
  end

  test "runtime_deps builds the full dependency map of function references" do
    deps = Runtime.runtime_deps()

    assert is_map(deps)
    assert Enum.all?(Map.values(deps), &is_function/1)
    assert Map.has_key?(deps, :config_target)
    assert Map.has_key?(deps, :load_config)
    assert Map.has_key?(deps, :setup_repo_state)
    assert Map.has_key?(deps, :create_labels)
  end

  test "setup_repo_state seeds an Executor handoff during init", %{dir: dir} do
    state_root = Path.join(dir, "state")
    source_root = Path.join(dir, "source")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    File.mkdir_p!(Path.join(source_root, ".git"))
    Application.put_env(:aiur, :repo_base_root, state_root)

    on_exit(fn ->
      case previous_root do
        nil -> Application.delete_env(:aiur, :repo_base_root)
        root -> Application.put_env(:aiur, :repo_base_root, root)
      end
    end)

    File.cd!(source_root, fn ->
      assert :ok = Runtime.setup_repo_state(%{kind: "github", repo: "owner/repo"})
    end)

    handoff = RepoBase.handoff_path("https://github.com/owner/repo.git")
    assert File.read!(handoff) == Templates.executor_handoff_template()
  end

  test "runtime_io builds the interactive IO map and puts writes output" do
    io = Runtime.runtime_io()

    for key <- [:puts, :input, :select, :multiselect, :confirm] do
      assert is_function(Map.fetch!(io, key))
    end

    assert io.puts.("aiur init runtime coverage line") == :ok
  end

  test "ensure_http_client starts the HTTP client and returns :ok" do
    assert Runtime.ensure_http_client() == :ok
  end

  defp match_result_type(:none), do: true

  defp match_result_type({:ok, %{language: language, build_root: root, command: command}}),
    do: is_atom(language) and is_binary(root) and is_binary(command)

  defp match_result_type({:ambiguous, candidates}) when is_list(candidates), do: true
  defp match_result_type(_), do: false
end
