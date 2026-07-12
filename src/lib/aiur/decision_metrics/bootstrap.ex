defmodule Aiur.DecisionMetrics.Bootstrap do
  @moduledoc "Starts the metrics writer and asynchronous canonical recovery pass."

  alias Aiur.DecisionMetrics.{Canonical, Writer}

  @writer_options [
    :sample_limit,
    :record_limit,
    :seen_limit,
    :batch_limit,
    :flush_interval_ms,
    :replay_record_limit,
    :replay_bytes,
    :replay_fun,
    :append_fun,
    :compact_fun
  ]

  @spec writer(keyword()) :: {GenServer.server(), boolean()}
  def writer(opts) do
    case Keyword.fetch(opts, :writer) do
      {:ok, writer} -> {writer, false}
      :error -> maybe_start_private_writer(opts)
    end
  end

  @spec start_seed(pid(), GenServer.server(), pos_integer(), keyword()) :: :ok
  def start_seed(owner, server, limit, opts) do
    if Keyword.get(opts, :seed?, true) do
      seed_fun = Keyword.get(opts, :seed_fun, &Canonical.snapshot/2)
      Task.start(fn -> run_seed(owner, seed_fun, server, limit) end)
    end

    :ok
  end

  defp maybe_start_private_writer(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) -> start_private_writer(path, opts)
      _other -> {Writer, false}
    end
  end

  defp start_private_writer(path, opts) do
    writer_opts = opts |> Keyword.take(@writer_options) |> Keyword.merge(name: nil, path: path)
    {:ok, writer} = Writer.start_link(writer_opts)
    {writer, true}
  end

  defp run_seed(owner, seed_fun, server, limit) do
    result = seed_fun.(server, limit)
    send(owner, {:canonical_seed, result})
  rescue
    error -> send(owner, {:canonical_seed_failed, Exception.message(error)})
  catch
    kind, reason -> send(owner, {:canonical_seed_failed, {kind, reason}})
  end
end
