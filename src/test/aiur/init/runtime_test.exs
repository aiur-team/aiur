defmodule Aiur.Init.RuntimeTest do
  use ExUnit.Case, async: false

  alias Aiur.Init.Runtime

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

  defp match_result_type(:none), do: true

  defp match_result_type({:ok, %{language: language, build_root: root, command: command}}),
    do: is_atom(language) and is_binary(root) and is_binary(command)

  defp match_result_type({:ambiguous, candidates}) when is_list(candidates), do: true
  defp match_result_type(_), do: false
end
