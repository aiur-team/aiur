defmodule Aiur.RepoBase.Probe do
  @moduledoc """
  Remote-head probe transitions for the `Aiur.RepoBase` server state. Each
  function takes and returns that state; `ensure_probe/2` must run in the
  server process, which receives the probe's messages.
  """

  @remote_probe_timeout_ms 30_000

  # An ls-remote probe answers "did the base branch advance?" without touching the base
  # working tree, so it is safe to run alongside an in-flight build.
  @doc false
  @spec ensure_probe(map(), String.t()) :: map()
  def ensure_probe(%{probe: nil, remote_head_fun: remote_head_fun} = state, repo_url) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:remote_head, self(), remote_head_fun.(repo_url)})
      end)

    timer = Process.send_after(self(), {:probe_timeout, ref}, @remote_probe_timeout_ms)
    %{state | probe: %{pid: pid, ref: ref, timer: timer}}
  end

  def ensure_probe(%{probe: %{pid: pid}} = state, repo_url) do
    if Process.alive?(pid), do: state, else: state |> clear_probe() |> ensure_probe(repo_url)
  end

  def ensure_probe(state, _repo_url), do: state

  @doc false
  @spec probe_freshness(map(), String.t()) :: map()
  def probe_freshness(state, repo_url) do
    state
    |> ensure_probe(repo_url)
    |> Map.put(:phase, :checking)
  end

  @doc false
  @spec confirm_freshness(map()) :: map()
  def confirm_freshness(%{phase: :checking} = state), do: %{state | phase: :ready, freshness: :fresh}
  def confirm_freshness(state), do: state

  # A failed probe must never certify a clone as current. Surface the failure so
  # the dispatcher deliberately takes its cold-clone fallback for this tick;
  # later scheduled refreshes can retry the probe/build without handing an
  # unverified warm base to a workspace.
  @doc false
  @spec probe_failed(map(), term()) :: map()
  def probe_failed(%{build: nil, phase: :checking} = state, reason) do
    %{state | phase: {:error, {:repo_base_remote_probe_failed, reason}}, freshness: :unknown}
  end

  def probe_failed(state, _reason), do: state

  # in-flight build is targeting an older head
  @doc false
  @spec advanced?(map(), term()) :: boolean()
  def advanced?(%{build: %{head: build_head}}, head)
      when is_binary(build_head) and is_binary(head),
      do: head != build_head

  # base is ready but the configured branch moved past it
  def advanced?(%{build: nil, phase: phase, ready_head: ready_head}, head)
      when phase in [:ready, :checking] and is_binary(head),
      do: head != ready_head

  def advanced?(_state, _head), do: false

  @doc false
  @spec abort_probe(map()) :: map()
  def abort_probe(%{probe: %{pid: pid}} = state) do
    Process.exit(pid, :kill)
    clear_probe(state)
  end

  def abort_probe(state), do: state

  @doc false
  @spec clear_probe(map()) :: map()
  def clear_probe(%{probe: %{ref: ref, timer: timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    Process.demonitor(ref, [:flush])
    %{state | probe: nil}
  end
end
