defmodule Aiur.ControlCall.KeyedReceipt do
  @moduledoc """
  At-most-once runs for local control commands that take a caller key.

  A reconciler that crashes after `aiur message --message-id K` (or
  `aiur rework --key K`) and runs it again must not queue a second message or
  a second run. The first call runs and records its receipt in
  `Aiur.ControlCall.ReplayStore`, the same fsync'd ledger that makes remote
  control writes replay-safe. A later call with the same key and the same
  arguments gets that receipt back without running anything; the same key
  with different arguments is refused. If the daemon died while the first call
  was running, the key reports an unknown outcome and the command is never run
  again under it. Entries live as long as the ledger keeps them (24 hours).
  """

  alias Aiur.ControlCall.ReplayStore

  @type receipt :: %{required(String.t()) => term()}
  @type result ::
          {:new, receipt()}
          | {:replay, receipt()}
          | {:error, :in_progress | :key_reused | :outcome_unknown | :unavailable | :full}

  @doc "Runs `fun` once for `{command, key}`; `fun` returns the JSON-safe receipt to keep."
  @spec run(String.t(), String.t(), term(), (-> receipt()), keyword()) :: result()
  def run(command, key, args, fun, opts \\ []) when is_binary(command) and is_binary(key) and is_function(fun, 0) do
    server = Keyword.get(opts, :server, ReplayStore)
    token = "cli:" <> command

    case safe(fn -> ReplayStore.claim(token, key, hash(command, args), server) end) do
      :new -> finish(token, key, fun.(), server)
      {:replay, 200, %{"receipt" => receipt}, _outcome} -> {:replay, receipt}
      {:replay, _status, _body, _outcome} -> {:error, :outcome_unknown}
      :in_progress -> {:error, :in_progress}
      :reused -> {:error, :key_reused}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Operator-facing text for a refused keyed run."
  @spec describe(atom()) :: String.t()
  def describe(:in_progress), do: "a call with this key is still running"
  def describe(:key_reused), do: "this key was already used with different arguments"
  def describe(:outcome_unknown), do: "the daemon stopped while a call with this key was running; check the ticket before using a new key"
  def describe(:full), do: "the receipt ledger is full"
  def describe(_unavailable), do: "the receipt ledger is unavailable"

  @doc "Exit status for a refused keyed run: 75 to retry later, 65 for a key clash, 69 otherwise."
  @spec exit_code(atom()) :: pos_integer()
  def exit_code(:in_progress), do: 75
  def exit_code(:key_reused), do: 65
  def exit_code(_reason), do: 69

  # The command ran; if its receipt cannot be recorded the ledger still holds
  # the `begin`, so a retry reports an unknown outcome instead of running again.
  defp finish(token, key, receipt, server) do
    _ = safe(fn -> ReplayStore.finish(token, key, 200, %{"receipt" => receipt}, "ok", server) end)
    {:new, receipt}
  end

  defp hash(command, args), do: :crypto.hash(:sha256, :erlang.term_to_binary({command, args})) |> Base.encode16(case: :lower)

  defp safe(fun) do
    fun.()
  rescue
    UndefinedFunctionError -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
