defmodule Aiur.OpenAICompat.ImageView do
  @moduledoc false
  # `view_image`: reads a workspace image and builds the user message that
  # carries it into the next provider request. Tool results stay text-only.

  alias Aiur.OpenAICompat.WorkspacePath

  @max_bytes 5 * 1024 * 1024

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec load(Path.t(), String.t()) :: {:ok, %{mime: String.t(), data: binary(), bytes: non_neg_integer()}} | {:error, String.t()}
  def load(workspace, path) do
    with {:ok, absolute} <- WorkspacePath.resolve(workspace, path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(absolute),
         :ok <- check_size(size),
         {:ok, data} <- File.read(absolute),
         {:ok, mime} <- mime(data) do
      {:ok, %{mime: mime, data: data, bytes: size}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, Atom.to_string(reason)}
      {:ok, %File.Stat{}} -> {:error, "not a regular file"}
    end
  end

  @spec message(:chat_completions | :responses, String.t(), map()) :: map()
  def message(transport, path, %{mime: mime, data: data}) do
    url = "data:#{mime};base64," <> Base.encode64(data)
    text = "Image from view_image: #{path}"

    parts =
      case transport do
        :responses -> [%{"type" => "input_text", "text" => text}, %{"type" => "input_image", "image_url" => url}]
        :chat_completions -> [%{"type" => "text", "text" => text}, %{"type" => "image_url", "image_url" => %{"url" => url}}]
      end

    %{"role" => "user", "content" => parts}
  end

  defp check_size(size) when size > @max_bytes, do: {:error, "file is #{size} bytes; view_image limit is #{@max_bytes} bytes"}
  defp check_size(_size), do: :ok

  defp mime(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  defp mime(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp mime(<<"GIF8", _, "a", _::binary>>), do: {:ok, "image/gif"}
  defp mime(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp mime(_), do: {:error, "not a PNG, JPEG, GIF or WebP image (size limit #{@max_bytes} bytes)"}
end
