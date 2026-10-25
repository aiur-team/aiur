defmodule Aiur.Orchestrator.Cancellation.Observation do
  @moduledoc false

  alias Aiur.Signal

  @contract "aiur.ticket_cancel"
  @contract_version 1
  @tracker_state "cancelled"
  @default_exit_timeout_ms 1_000

  @type process_status :: :exited | :still_running | :kill_failed | :generation_changed
  @type result :: %{
          contract: String.t(),
          contract_version: pos_integer(),
          issue_identifier: String.t(),
          tracker_state: String.t(),
          process: %{
            handle: String.t(),
            status: String.t(),
            exit_status: String.t() | nil,
            exited_at: String.t() | nil,
            observed_at: String.t()
          }
        }

  @spec observe_exit(reference(), pid(), String.t(), String.t(), term(), keyword()) :: result()
  def observe_exit(monitor, pid, handle, identifier, stop_result, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_exit_timeout_ms)

    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        result(identifier, handle, :exited, reason, now(opts))
    after
      timeout_ms ->
        Process.demonitor(monitor, [:flush])
        status = if stop_result == :ok, do: :still_running, else: :kill_failed
        result(identifier, handle, status, nil, now(opts))
    end
  end

  @spec result(String.t(), String.t(), process_status(), term(), DateTime.t()) :: result()
  def result(identifier, handle, status, exit_reason, %DateTime{} = observed_at)
      when is_binary(identifier) and is_binary(handle) and
             status in [:exited, :still_running, :kill_failed, :generation_changed] do
    observed_at = DateTime.to_iso8601(observed_at)
    exited? = status == :exited

    %{
      contract: @contract,
      contract_version: @contract_version,
      issue_identifier: identifier,
      tracker_state: @tracker_state,
      process: %{
        handle: handle,
        status: Atom.to_string(status),
        exit_status: if(exited?, do: Signal.reason_class(exit_reason), else: nil),
        exited_at: if(exited?, do: observed_at, else: nil),
        observed_at: observed_at
      }
    }
  end

  @doc false
  @spec request_stop((pid() -> term()), pid()) :: term()
  def request_stop(stop_fun, pid) do
    stop_fun.(pid)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec now(keyword()) :: DateTime.t()
  def now(opts) do
    opts
    |> Keyword.get(:now_fun, &DateTime.utc_now/0)
    |> then(& &1.())
  end
end
