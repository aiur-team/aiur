defmodule Aiur.VoiceConversation.Comparison do
  @moduledoc "Durable comparison lines beside transcripts, with cumulative minute reservations."

  alias Aiur.Fs

  # Evaluation allocations, not vendor tariffs or invoice limits.
  @budgets %{"openai_realtime" => {45 * 60, 8.0}, "elevenlabs_agents" => {45 * 60, 8.0}}

  @spec snapshot(Path.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(root) do
    with {:ok, rows} <- read(root) do
      meters = for {provider, {cap, dollars}} <- @budgets, do: %{provider: provider, used_seconds: used(rows, provider), cap_seconds: cap, allocation_usd: dollars}
      {:ok, %{rows: rows, meters: meters}}
    end
  end

  @spec reserve(Path.t(), String.t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def reserve(root, provider, model, max_seconds) when is_integer(max_seconds) and max_seconds > 0 do
    locked(root, fn ->
      with {:ok, {cap, _dollars}} <- Map.fetch(@budgets, provider),
           {:ok, rows} <- read(root),
           remaining when remaining > 0 <- cap - used(rows, provider) do
        row = new_row(provider, model, min(remaining, max_seconds))
        with :ok <- write(root, rows ++ [row]), do: {:ok, row}
      else
        :error -> {:error, :invalid_provider}
        remaining when is_number(remaining) -> {:error, :cost_cap}
        error -> error
      end
    end)
  end

  def reserve(_root, _provider, _model, _max_seconds), do: {:error, :invalid_limit}

  @spec finish(Path.t(), String.t(), String.t(), non_neg_integer(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def finish(root, token, session_id, elapsed_ms, first_audio_ms) do
    update(root, token, fn row ->
      seconds = min(row["reserved_seconds"], elapsed_ms / 1_000)
      {cap, dollars} = Map.fetch!(@budgets, row["provider"])

      Map.merge(row, %{
        "session_id" => session_id,
        "status" => "ended",
        "seconds" => seconds,
        "minutes" => seconds / 60,
        "first_audio_ms" => first_audio_ms,
        "estimated_cost_usd" => seconds / cap * dollars
      })
    end)
  end

  @spec rate(Path.t(), String.t(), integer(), String.t()) :: :ok | {:error, term()}
  def rate(root, token, rating, note) when rating in 1..5 and is_binary(note) and byte_size(note) <= 2_000 do
    update(root, token, &Map.merge(&1, %{"rating" => rating, "note" => VoiceConverse.Redact.redact(note)}))
  end

  def rate(_root, _token, _rating, _note), do: {:error, :invalid_rating}

  defp new_row(provider, model, seconds) do
    %{
      "id" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "provider" => provider,
      "model" => model,
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "status" => "reserved",
      "reserved_seconds" => seconds,
      "rating" => nil,
      "note" => "",
      "first_audio_ms" => nil
    }
  end

  defp used(rows, provider) do
    rows |> Enum.filter(&(&1["provider"] == provider)) |> Enum.reduce(0, &(&2 + Map.get(&1, "seconds", &1["reserved_seconds"]))) |> ceil()
  end

  defp update(root, token, fun) do
    locked(root, fn ->
      with {:ok, rows} <- read(root),
           true <- Enum.any?(rows, &(&1["id"] == token)) do
        write(root, Enum.map(rows, fn row -> if row["id"] == token, do: fun.(row), else: row end))
      else
        false -> {:error, :not_found}
        error -> error
      end
    end)
  end

  defp read(root) do
    case File.read(Path.join(root, "comparison.json")) do
      {:ok, json} -> decode(json)
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end

  defp decode(json) do
    with {:ok, rows} when is_list(rows) <- Jason.decode(json),
         true <- Enum.all?(rows, &valid_row?/1) do
      {:ok, rows}
    else
      _ -> {:error, :comparison_unavailable}
    end
  end

  defp valid_row?(%{"id" => id, "provider" => provider, "reserved_seconds" => seconds} = row) do
    is_binary(id) and Map.has_key?(@budgets, provider) and is_number(seconds) and seconds >= 0 and
      (not Map.has_key?(row, "seconds") or (is_number(row["seconds"]) and row["seconds"] >= 0))
  end

  defp valid_row?(_row), do: false

  defp write(root, rows) do
    with :ok <- ensure_root(root),
         :ok <- Fs.atomic_write(Path.join(root, "comparison.json"), Jason.encode!(rows), fsync: true, mode: 0o600) do
      Fs.sync_filesystem()
    end
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:error, :enoent} ->
        with :ok <- File.mkdir_p(root), do: File.chmod(root, 0o700)

      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 ->
        :ok

      _ ->
        {:error, :insecure_comparison_root}
    end
  end

  defp locked(root, fun), do: :global.trans({{__MODULE__, Path.expand(root)}, self()}, fun)
end
