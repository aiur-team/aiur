defmodule Aiur.Executor.AttachCLI do
  @moduledoc false
  alias Aiur.Executor.{HookConfig, HookToken, Session, SessionCLI}
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @spec attach(keyword()) :: :ok
  def attach(opts), do: guarded("executor-attach", fn -> opts |> run_attach() |> exit_marker() end)
  @spec detach(keyword()) :: :ok
  def detach(opts), do: guarded("executor-detach", fn -> opts |> run_detach() |> exit_marker() end)

  @spec run_attach(keyword()) :: non_neg_integer()
  def run_attach(opts) do
    with :ok <- validate(opts),
         :ok <- listener(opts),
         :ok <- HookToken.ensure(),
         previous <- Session.current(),
         {:ok, binding} <- Session.attach(%{harness: opts[:harness], takeover?: opts[:takeover?] == true}) do
      if opts[:takeover?] && match?({:ok, %{live?: true}}, previous), do: IO.puts("SUPERSEDED binding=#{elem(previous, 1).binding_id}")
      IO.puts("ATTACHED binding=#{binding.binding_id} harness=#{binding.harness} state=#{binding.state}")
      configure(binding.harness, opts)
    else
      error -> failure(error)
    end
  end

  @spec run_detach(keyword()) :: non_neg_integer()
  def run_detach(opts) do
    with {:ok, binding} <- Session.current(),
         {:ok, _binding} <- Session.detach(binding.binding_id, "stopped"),
         :ok <- HookToken.rotate() do
      IO.puts("DETACHED binding=#{binding.binding_id}")
      uninstall(binding.harness, opts)
    else
      :none ->
        IO.puts("DETACHED (no Executor binding)")
        0

      error ->
        failure(error)
    end
  end

  defp validate(opts) do
    cond do
      opts[:harness] not in ["claude", "codex"] -> {:failure, 64, "executor-attach requires --harness claude or codex"}
      System.get_env("AIUR_INSTANCE_KEY") in [nil, ""] -> {:error, :missing_instance_key}
      true -> :ok
    end
  end

  defp listener(opts) do
    port = Keyword.get_lazy(opts, :bound_port, &Aiur.HttpServer.bound_port/0)
    if is_integer(port), do: :ok, else: {:failure, 69, "the Executor hook needs the dashboard listener; restart without --no-dashboard"}
  end

  defp configure(harness, opts) do
    if harness == "codex" or opts[:print_config] do
      IO.puts(HookConfig.render(if(harness == "claude", do: :claude, else: :codex)))
      IO.puts("Next: review the hooks, then start or resume the Executor session.")
      0
    else
      case HookConfig.install(Keyword.fetch!(opts, :repo_root)) do
        :ok ->
          IO.puts("Next: start or resume Claude in this repository and confirm its hooks are enabled.")
          0

        error ->
          install_failure(error, opts)
      end
    end
  end

  defp uninstall("claude", opts) do
    case HookConfig.uninstall(Keyword.fetch!(opts, :repo_root)) do
      :ok -> 0
      error -> install_failure(error, opts)
    end
  end

  defp uninstall("codex", _opts), do: 0

  defp install_failure(error, opts), do: failure({:failure, 73, "cannot update #{Path.join(opts[:repo_root], ".claude/settings.local.json")}: #{inspect(error)}; use --print-config to print hooks"})

  defp failure({:error, {:already_attached, binding}}) do
    age = SessionCLI.age(binding, DateTime.utc_now())
    failure({:failure, 75, "already attached binding=#{binding.binding_id} harness=#{binding.harness} age_ms=#{age.age_ms || "unknown"}; use --takeover"})
  end

  defp failure({:error, :missing_instance_key}), do: failure({:failure, 69, "Executor hooks require a nonempty AIUR_INSTANCE_KEY; restart the instance"})

  defp failure({:failure, code, message}) do
    IO.puts("aiur: #{message}")
    code
  end

  defp failure(error), do: failure({:failure, 73, "Executor binding operation failed: #{inspect(error)}"})
end
