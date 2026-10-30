defmodule VoiceConverse.Transcripts do
  @moduledoc "List and display stored conversations without starting a voice host."
  alias VoiceConverse.{TranscriptIndex, TranscriptStore}
  alias VoiceConverse.Transcripts.Format

  @spec run(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(root, args) do
    with {:ok, opts, ids} <- options(args) do
      case ids do
        [] -> list(root, opts)
        [id] -> if(opts[:delete], do: delete(root, id, opts), else: show(root, id, opts))
      end
    end
  end

  @spec print(Path.t(), [String.t()]) :: 0 | 1 | 64
  def print(root, args) do
    case run(root, args) do
      {:ok, output} ->
        IO.puts(output)
        0

      {:error, :invalid_arguments} ->
        IO.puts(:stderr, "Invalid transcript arguments")
        64

      {:error, :active_conversation} ->
        IO.puts(:stderr, "End the conversation first")
        1

      {:error, :not_found} ->
        IO.puts(:stderr, "No such conversation")
        1

      {:error, reason} ->
        IO.puts(:stderr, "Cannot read voice transcripts: #{inspect(reason)}")
        1
    end
  end

  defp options(args) do
    {opts, ids, invalid} =
      OptionParser.parse(args,
        strict: [target: :string, limit: :integer, json: :boolean, delete: :boolean, confirm: :string]
      )

    target = opts[:target]
    valid_target = is_nil(target) or Regex.match?(~r/\A[A-Za-z0-9#\/_.-]{1,80}\z/, target)
    valid_limit = Keyword.get(opts, :limit, 100) in 1..100
    valid_id = ids == [] or (length(ids) == 1 and Regex.match?(~r/\Avc_[A-Za-z0-9_-]{22}\z/, hd(ids)))
    list_only = ids == [] or not (Keyword.has_key?(opts, :target) or Keyword.has_key?(opts, :limit))

    deletion = opts[:delete] != true or (length(ids) == 1 and opts[:confirm] == hd(ids) and opts[:json] != true)
    confirmation = not Keyword.has_key?(opts, :confirm) or opts[:delete] == true

    if invalid == [] and valid_target and valid_limit and valid_id and list_only and deletion and confirmation,
      do: {:ok, opts, ids},
      else: {:error, :invalid_arguments}
  end

  defp list(root, opts) do
    with {:ok, records, _cursor} <-
           TranscriptIndex.list(root, filter: %{target: opts[:target]}, limit: Keyword.get(opts, :limit, 100)) do
      {:ok, if(opts[:json], do: Jason.encode!(records), else: Format.list(records))}
    end
  end

  defp delete(root, id, opts) do
    with :ok <- TranscriptStore.delete(root, id, confirm: opts[:confirm], by: "operator") do
      {:ok, "Deleted conversation #{id}"}
    end
  end

  defp show(root, id, opts) do
    with {:ok, records, meta} <- TranscriptStore.read(root, id) do
      {:ok, if(opts[:json], do: Jason.encode!(records), else: Format.show(records, meta))}
    end
  end
end
