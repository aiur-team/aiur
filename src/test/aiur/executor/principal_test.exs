defmodule Aiur.Executor.PrincipalTest do
  use ExUnit.Case, async: false

  alias Aiur.Executor.{Claims, Principal}

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-executor-principal")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "claims.json")}
  end

  test "registers and renews the launched Executor principal", %{path: path} do
    name = Module.concat(__MODULE__, Renewing)

    start_supervised!(
      {Principal, name: name, consumer_id: "executor-a", path: path, renew_interval_ms: 10},
      id: name
    )

    first = entry(path, "executor-a")

    assert first["role"] == "owner"
    assert is_binary(first["last_renewed_at"])

    renewed = eventually(fn -> renewed_entry(path, "executor-a", first["last_renewed_at"]) end)

    assert renewed["last_acknowledged_at"] == nil
    assert renewed["acknowledged_count"] == 0
  end

  test "registers as an observer when another Executor owns the stream", %{path: path} do
    {:ok, owner} = Claims.claim("executor-a", path: path)
    name = Module.concat(__MODULE__, Observer)

    start_supervised!(
      {Principal, name: name, consumer_id: "executor-b", path: path, renew_interval_ms: 10},
      id: name
    )

    observer = entry(path, "executor-b")

    assert owner["role"] == "owner"
    assert observer["role"] == "observer"
    assert is_binary(observer["last_renewed_at"])

    renewed = eventually(fn -> renewed_entry(path, "executor-b", observer["last_renewed_at"]) end)

    assert renewed["role"] == "observer"
    assert {:ok, %{"id" => "executor-a"}} = Claims.owner(path: path)
  end

  test "releases the principal when its supervision ends", %{path: path} do
    name = Module.concat(__MODULE__, Releasing)

    start_supervised!(
      {Principal, name: name, consumer_id: "executor-a", path: path, renew_interval_ms: 10},
      id: name
    )

    assert {:ok, %{"id" => "executor-a"}} = Claims.owner(path: path)
    assert :ok = stop_supervised(name)
    assert :none = Claims.owner(path: path)
  end

  defp entry(path, id) do
    eventually(fn -> Enum.find(Claims.entries(path: path), &(&1["id"] == id)) end)
  end

  defp renewed_entry(path, id, previous) do
    case Enum.find(Claims.entries(path: path), &(&1["id"] == id)) do
      %{"last_renewed_at" => renewed} = entry when renewed != previous -> entry
      _not_renewed -> nil
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      result when result in [false, nil] ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")
end
