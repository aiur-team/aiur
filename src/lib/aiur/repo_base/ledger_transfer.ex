defmodule Aiur.RepoBase.LedgerTransfer do
  @moduledoc """
  Exactly-once merge of a legacy findings or asks ledger into its canonical
  `Aiur.RepoBase` state path, with a checksum marker for crash recovery and
  per-record validation of both sides.
  """

  alias Aiur.Fs
  alias Aiur.RepoBase.Ledger
  alias Aiur.RepoBase.StateTree

  @findings_transfer_suffix ".migration-transfer"
  @asks_transfer_suffix ".asks-migration-transfer"

  @doc false
  @spec merge_findings(Path.t(), Path.t()) :: :ok | {:error, term()}
  def merge_findings(source, destination), do: merge_ledger(source, destination, :findings)
  @doc false
  @spec merge_asks(Path.t(), Path.t()) :: :ok | {:error, term()}
  def merge_asks(source, destination), do: merge_ledger(source, destination, :asks)

  defp merge_ledger(source, destination, ledger) do
    with :ok <- ensure_ledger_paths_safe(destination, ledger),
         :ok <- recover_ledger_transfer(destination, source, ledger) do
      write_ledger_transfer(source, destination, ledger)
    end
  end

  # A source ledger must be transferred exactly once. Appending then deleting
  # loses that property if a process dies between the two operations, so stage
  # an explicit checksum checkpoint and atomically replace the destination.
  # Recovery can then distinguish a completed replacement from an unstarted
  # one without treating repeated, legitimate observations as duplicates.
  defp write_ledger_transfer(source, destination, ledger) do
    with :ok <- ensure_regular_file(source),
         {:ok, destination_contents} <- Ledger.read_ledger(destination, ledger, Ledger.validator(ledger)),
         {:ok, source_contents} <- Ledger.read_ledger(source, ledger, Ledger.validator(ledger)),
         merged_contents <- destination_contents <> merged_findings_suffix(destination_contents, source_contents),
         :ok <- Ledger.validate(merged_contents, destination, ledger, Ledger.validator(ledger)),
         :ok <- write_ledger_transfer_marker(source, destination, destination_contents, source_contents, merged_contents, ledger),
         :ok <- replace_file(destination, merged_contents),
         :ok <- File.rm(source),
         :ok <- Fs.sync_filesystem(),
         :ok <- File.rm(ledger_transfer_marker(destination, ledger)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec recover_ledger_transfer(Path.t(), Path.t(), :findings | :asks) :: :ok | {:error, term()}
  def recover_ledger_transfer(destination, expected_source, ledger) do
    marker = ledger_transfer_marker(destination, ledger)

    with :ok <- ensure_ledger_paths_safe(destination, ledger),
         :ok <- ensure_transfer_source_safe(expected_source) do
      case File.read(marker) do
        {:error, :enoent} ->
          :ok

        {:ok, contents} ->
          recover_ledger_transfer_contents(contents, destination, expected_source, marker, ledger)

        {:error, reason} ->
          {:error, {transfer_error_tag(ledger), destination, reason}}
      end
    end
  end

  defp ensure_transfer_source_safe(source) do
    parked_clone = source |> Path.dirname() |> Path.dirname()
    StateTree.ensure_state_path_safe(parked_clone, source)
  end

  defp recover_ledger_transfer_contents(contents, destination, expected_source, marker, ledger) do
    with {:ok, transfer} <- Jason.decode(contents),
         :ok <- validate_ledger_transfer(transfer, destination, expected_source),
         {:ok, destination_contents} <- File.read(destination) do
      transfer
      |> recover_ledger_transfer_state(destination, destination_contents, marker, ledger)
      |> wrap_ledger_recovery_error(destination, ledger)
    else
      {:error, reason} -> {:error, {transfer_error_tag(ledger), destination, reason}}
    end
  end

  defp recover_ledger_transfer_state(transfer, destination, contents, marker, ledger) do
    source = transfer["source"]

    cond do
      digest(contents) == transfer["merged_hash"] ->
        case remove_transfer_source(source, transfer["source_hash"]) do
          :ok -> File.rm(marker)
          {:error, _reason} = error -> error
        end

      digest(contents) == transfer["destination_hash"] and regular_file?(source) ->
        File.rm(marker)

      true ->
        {:error, {transfer_inconsistent_tag(ledger), destination}}
    end
  end

  defp wrap_ledger_recovery_error(:ok, _destination, _ledger), do: :ok

  defp wrap_ledger_recovery_error({:error, reason}, destination, ledger),
    do: {:error, {transfer_error_tag(ledger), destination, reason}}

  defp validate_ledger_transfer(transfer, destination, expected_source) when is_map(transfer) do
    required = ["source", "source_hash", "destination", "destination_hash", "merged_hash"]

    cond do
      transfer["destination"] != destination ->
        {:error, :invalid_marker}

      not Enum.all?(required, &(is_binary(transfer[&1]) and transfer[&1] != "")) ->
        {:error, :invalid_marker}

      Path.expand(transfer["source"]) != Path.expand(expected_source) ->
        {:error, :invalid_source}

      true ->
        :ok
    end
  end

  defp validate_ledger_transfer(_transfer, _destination, _expected_source), do: {:error, :invalid_marker}

  defp remove_transfer_source(source, source_hash) do
    case File.lstat(source) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> remove_matching_transfer_source(source, source_hash)
      {:ok, _stat} -> {:error, :source_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_matching_transfer_source(source, source_hash) do
    with {:ok, contents} <- File.read(source) do
      if digest(contents) == source_hash, do: File.rm(source), else: {:error, :source_changed}
    end
  end

  defp regular_file?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

  defp write_ledger_transfer_marker(source, destination, destination_contents, source_contents, merged_contents, ledger) do
    marker_contents =
      Jason.encode!(%{
        "source" => source,
        "source_hash" => digest(source_contents),
        "destination" => destination,
        "destination_hash" => digest(destination_contents),
        "merged_hash" => digest(merged_contents)
      })

    case Fs.atomic_write(ledger_transfer_marker(destination, ledger), marker_contents, fsync: true) do
      :ok -> Fs.sync_filesystem()
      {:error, _reason} = error -> error
    end
  end

  defp ledger_transfer_marker(destination, :findings), do: destination <> @findings_transfer_suffix
  defp ledger_transfer_marker(destination, :asks), do: destination <> @asks_transfer_suffix
  defp transfer_error_tag(:findings), do: :findings_transfer_recovery_failed
  defp transfer_error_tag(:asks), do: :asks_transfer_recovery_failed
  defp transfer_inconsistent_tag(:findings), do: :findings_transfer_inconsistent
  defp transfer_inconsistent_tag(:asks), do: :asks_transfer_inconsistent

  defp replace_file(destination, contents) do
    case Fs.atomic_write(destination, contents, fsync: true) do
      :ok -> Fs.sync_filesystem()
      {:error, _reason} = error -> error
    end
  end

  defp ensure_ledger_paths_safe(destination, ledger) do
    node = destination |> Path.dirname() |> Path.dirname()

    case StateTree.ensure_state_path_safe(node, destination) do
      :ok -> StateTree.ensure_state_path_safe(node, ledger_transfer_marker(destination, ledger))
      {:error, _reason} = error -> error
    end
  end

  defp ensure_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, {:repo_base_findings_source_invalid, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  # A valid final NDJSON record need not end in a newline. Canonicalize both
  # sides before joining so a later O_APPEND writer cannot join two JSON objects
  # at a record boundary. Invalid input remains in place for manual repair.
  defp merged_findings_suffix(destination_contents, source_contents) do
    normalized_source = normalize_ndjson(source_contents)

    if destination_contents == "" or String.ends_with?(destination_contents, "\n") do
      normalized_source
    else
      "\n" <> normalized_source
    end
  end

  defp normalize_ndjson(""), do: ""
  defp normalize_ndjson(contents), do: if(String.ends_with?(contents, "\n"), do: contents, else: contents <> "\n")
end
