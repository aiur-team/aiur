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
