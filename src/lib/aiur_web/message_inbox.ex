defmodule AiurWeb.MessageInbox do
  @moduledoc """
  Attachments sent with an operator message to a ticket's worker.

  Each attachment is written into the worker's workspace under
  `.aiur/inbox/<message>/`, and the message text gains one line per file naming
  its workspace-relative path, so the worker can open it. Types and size caps
  follow Command media (`Aiur.Commands.Media`): images, audio and video.
  """

  alias Aiur.Commands.Media

  @kinds [:image, :animated_image, :audio, :video]
  @max_attachments 8
  @inbox ".aiur/inbox"

  @type attachment :: %{required(String.t()) => String.t()}

  @doc """
  Validates `attachments` (`[%{"name", "mime_type", "data"}]`, data base64) and
  writes them under `workspace`. Returns the lines to append to the message.
  """
  @spec write(String.t(), String.t(), [attachment()]) :: {:ok, [String.t()]} | {:error, atom()}
  def write(_workspace, _folder, []), do: {:ok, []}
  def write(_workspace, _folder, attachments) when length(attachments) > @max_attachments, do: {:error, :too_many_attachments}

  def write(workspace, folder, attachments) when is_binary(workspace) and is_binary(folder) and is_list(attachments) do
    with {:ok, files} <- decode_all(attachments),
         true <- File.dir?(workspace) || {:error, :workspace_unavailable},
         dir = Path.join([@inbox, safe_segment(folder)]),
         :ok <- File.mkdir_p(Path.join(workspace, dir)) do
      write_files(workspace, dir, files)
    end
  end

  def write(_workspace, _folder, _attachments), do: {:error, :invalid_attachments}

  @doc "The message text with its attachment lines appended."
  @spec append(String.t(), [String.t()]) :: String.t()
  def append(text, []), do: text
  def append(text, lines), do: String.trim_trailing(text) <> "\n\n" <> Enum.join(lines, "\n")

  defp decode_all(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case decode(attachment) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp decode(%{"name" => name, "mime_type" => mime, "data" => data}) when is_binary(name) and is_binary(mime) and is_binary(data) do
    with {:ok, kind} <- kind(mime),
         {:ok, bytes} <- base64(data),
         :ok <- within_cap(kind, bytes),
         {:ok, name} <- file_name(name) do
      {:ok, {name, bytes}}
    end
  end

  defp decode(_attachment), do: {:error, :invalid_attachments}

  defp kind(mime) do
    case Enum.find(@kinds, &(mime in Media.mime_types(&1))) do
      nil -> {:error, :unsupported_attachment_type}
      kind -> {:ok, kind}
    end
  end

  defp base64(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      _invalid -> {:error, :invalid_attachment_data}
    end
  end

  defp within_cap(kind, bytes), do: if(byte_size(bytes) <= Media.max_bytes(kind), do: :ok, else: {:error, :attachment_too_large})

  # Keeps the name's last segment and replaces anything outside a conservative
  # set, so a name can never leave the inbox folder.
  defp file_name(name) do
    case name |> Path.basename() |> safe_segment() do
      "" -> {:error, :invalid_attachments}
      safe -> {:ok, safe}
    end
  end

  defp safe_segment(value), do: value |> String.replace(~r/[^A-Za-z0-9._-]/, "_") |> String.trim_leading(".") |> String.slice(0, 120)

  defp write_files(workspace, dir, files) do
    Enum.reduce_while(files, {:ok, []}, fn {name, bytes}, {:ok, acc} ->
      digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) |> binary_part(0, 16)
      stored_name = "#{Path.rootname(name)}-#{digest}#{Path.extname(name)}"
      relative = Path.join(dir, stored_name)
      path = Path.join(workspace, relative)

      result =
        case File.write(path, bytes, [:binary, :exclusive]) do
          :ok -> :ok
          {:error, :eexist} -> existing_file(path, bytes)
          {:error, _} -> {:error, :attachment_write_failed}
        end

      case result do
        :ok -> {:cont, {:ok, ["Attachment: #{relative}" | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end

  defp existing_file(path, bytes) do
    case File.read(path) do
      {:ok, ^bytes} -> :ok
      _different -> {:error, :attachment_collision}
    end
  end
end
