defmodule Aiur.TestSupport.CodeownersGuardState do
  @moduledoc false
  alias Aiur.GitHub.CodeOwners
  @pid_key {__MODULE__, :registered_pid}

  def capture do
    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        :persistent_term.put(@pid_key, pid)
        %{allowlist: CodeOwners.snapshot(pid), codeowners: CodeOwners.codeowners_snapshot(pid)}

      _ ->
        :persistent_term.put(@pid_key, nil)
        nil
    end
  end

  def unregistered?, do: is_pid(saved_pid()) and is_nil(Process.whereis(CodeOwners))

  def leaks(expected, test_name) when expected in [:unset, nil] do
    if unregistered?(), do: [unregistered_leak(test_name)], else: []
  end

  def leaks(expected, test_name) do
    if unregistered?(), do: [unregistered_leak(test_name)], else: registered_leaks(expected)
  end

  defp registered_leaks(expected) do
    case Process.whereis(CodeOwners) do
      nil -> []
      pid -> if state(pid) == expected, do: [], else: ["Aiur.GitHub.CodeOwners changed from #{inspect(expected)} to #{inspect(state(pid))}"]
    end
  end

  defp unregistered_leak(test_name), do: "Aiur.GitHub.CodeOwners unregistered during #{test_name || "unknown"}"

  defp state(pid), do: %{allowlist: CodeOwners.snapshot(pid), codeowners: CodeOwners.codeowners_snapshot(pid)}

  def restore(%{allowlist: allowlist, codeowners: codeowners}) do
    case Process.whereis(CodeOwners) || saved_pid() do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(allowlist), codeowners: MapSet.new(codeowners)})
        if is_nil(Process.whereis(CodeOwners)), do: Process.register(pid, CodeOwners)

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  def restore(_), do: :ok

  defp saved_pid do
    case :persistent_term.get(@pid_key, nil) do
      pid when is_pid(pid) -> if(Process.alive?(pid), do: pid)
      _ -> nil
    end
  end
end
