defmodule Aiur.Executor.CheckCLI do
  @moduledoc false
  import Bitwise, only: [band: 2]
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]
  alias Aiur.Executor.{HookConfig, HookMerge, HookToken, Session}

  @spec rpc(keyword()) :: :ok
  def rpc(opts), do: guarded("executor-attach --check", fn -> opts |> run() |> exit_marker() end)

  @spec run(keyword()) :: 0 | 1
  def run(opts) do
    rows = checks(opts)
    IO.puts(if opts[:json], do: Jason.encode!(rows), else: Enum.map_join(rows, "\n", &"#{&1.check}: #{&1.status} — #{&1.detail}"))
    if Enum.all?(rows, &(&1.status == :ok)), do: 0, else: 1
  end

  @spec checks(keyword()) :: [map()]
  def checks(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    binding =
      case Session.current() do
        {:ok, %{state: state} = binding} when state != "detached" -> binding
        _ -> nil
      end

    [
      {:listener,
       if(is_integer(opts[:bound_port]), do: {:ok, "dashboard listener is bound"}, else: {:fail, "dashboard listener is off (started with --no-dashboard); restart without --no-dashboard"})},
      {:binding, if(binding, do: {:ok, "Executor binding exists"}, else: {:fail, "not attached: run aiur executor-attach --harness claude|codex"})},
      {:credentials, credentials()},
      {:hooks, hooks(binding, opts)},
      {:hook_age, hook_age(binding, now)},
      {:transcript, transcript(binding)},
      {:drift, drift(binding)}
    ]
    |> Enum.map(fn {check, {status, detail}} -> %{check: check, status: status, detail: detail, observed_at: DateTime.to_iso8601(now)} end)
  end

  defp credentials do
    paths = [HookToken.path(), HookToken.headers_path(), HookConfig.url_path()]

    if Enum.all?(paths, &private_file?/1),
      do: {:ok, "hook credential files are present and private (0600)"},
      else: {:fail, "hook credentials missing or readable by others; run aiur executor-attach --harness claude|codex again"}
  rescue
    ArgumentError -> {:fail, "hook credentials missing or readable by others; restart with an instance key and attach again"}
  end

  defp private_file?(path) do
    with {:ok, %{type: :regular, mode: mode, size: size}} <- File.lstat(path),
         true <- band(mode, 0o777) == 0o600 and size > 0,
         {:ok, file} <- File.open(path, [:read]) do
      File.close(file) == :ok
    else
      _ -> false
    end
  end

  defp hooks(nil, _opts), do: {:unknown, "attach an Executor before checking its hooks"}
  defp hooks(%{harness: "codex", last_hook_at: nil}, _opts), do: {:unknown, "no hook yet: review and trust the hooks in Codex"}
  defp hooks(%{harness: "codex"}, _opts), do: {:ok, "Codex hook received"}

  defp hooks(%{harness: "claude"}, opts) do
    path = Path.join([Keyword.fetch!(opts, :repo_root), ".claude", "settings.local.json"])

    with {:ok, body} <- File.read(path),
         {:ok, config} <- Jason.decode(body),
         true <- HookMerge.valid?(config),
         true <- installed?(config) do
      {:ok, "Claude hooks are installed"}
    else
      _ -> {:fail, "hooks not installed; run aiur executor-attach --harness claude in this repository"}
    end
  end

  defp installed?(config) do
    Enum.all?(HookConfig.entries(:claude), fn {event, groups} ->
      expected = for group <- groups, hook <- group["hooks"], do: hook["command"]
      actual = for group <- get_in(config, ["hooks", event]) || [], hook <- group["hooks"], do: hook["command"]
      Enum.all?(expected, &(&1 in actual))
    end)
  end

  defp hook_age(nil, _now), do: {:unknown, "no hook yet; attach an Executor and start or resume its session"}
  defp hook_age(%{last_hook_at: nil}, _now), do: {:unknown, "no hook yet; start or resume the Executor and enable its hooks"}

  defp hook_age(binding, now) do
    {:ok, at, _} = DateTime.from_iso8601(binding.last_hook_at)
    age = max(DateTime.diff(now, at, :millisecond), 0)

    if age <= Application.get_env(:aiur, :executor_session_ttl_ms, 600_000),
      do: {:ok, "last hook #{div(age, 60_000)} min ago"},
      else: {:fail, "no hook for #{div(age, 60_000)} min; resume the Executor and confirm hooks are enabled"}
  end

  defp transcript(%{transcript_path: path}) when is_binary(path) do
    with {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read]) do
      File.close(file)
      {:ok, "transcript is readable"}
    else
      {:ok, _stat} -> {:fail, "transcript unreadable: not a regular file; resume the Executor to refresh its path"}
      {:error, reason} -> {:fail, "transcript unreadable: #{reason}; resume the Executor to refresh its path and permissions"}
    end
  end

  defp transcript(_binding), do: {:unknown, "transcript path unknown; start or resume the Executor to send a hook"}

  defp drift(%{harness: "codex"}), do: {:ok, "Claude transcript drift check does not apply to Codex"}

  defp drift(%{transcript_format: %{"alerted" => true} = counts}),
    do: {:fail, "transcript format changed (version #{counts["untested_version"] || "unknown"}); update the transcript adapter before reattaching"}

  defp drift(%{transcript_format: %{"total" => total}}) when total > 0, do: {:ok, "no transcript format drift latched"}
  defp drift(_binding), do: {:unknown, "transcript format unknown; wait for transcript records after the first hook"}
end
