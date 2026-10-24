defmodule Aiur.Instance.LeaderFence do
  @moduledoc "Fail-closed write fence for repository-wide GitHub services."

  alias Aiur.Instance.LeaseStore

  @repo_global_callers ~w(landing_watch quarantine_ main_watch main_fixer)
  @repo_global_exact_callers ~w(main_watch_canary main_watch_single_test_rerun)

  @spec allowed?() :: boolean()
  def allowed? do
    if Aiur.Config.instance_role() == "secondary" do
      false
    else
      case LeaseStore.leader_owned?(Aiur.GitHub.Config.repo()) do
        true -> true
        :disabled -> true
        _ -> false
      end
    end
  rescue
    _ -> false
  end

  @spec repo_global_write?(map()) :: boolean()
  def repo_global_write?(%{method: method, caller: caller}) when method in [:post, :put, :patch, :delete] and is_binary(caller) do
    caller in @repo_global_exact_callers or Enum.any?(@repo_global_callers, &String.starts_with?(caller, &1))
  end

  def repo_global_write?(_request), do: false

  @doc false
  @spec run(map(), (-> boolean()), (-> term())) :: term()
  def run(request, allowed_fun, write_fun) do
    if repo_global_write?(request) and not allowed_fun.() do
      error()
    else
      write_fun.()
    end
  end

  @spec error() :: {:error, {:repository_leader_fence, :not_owner}}
  def error, do: {:error, {:repository_leader_fence, :not_owner}}
end
