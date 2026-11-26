defmodule VoiceConverse.Tools.CommandAnswer do
  @moduledoc """
  The `answer_command` provider tool: submits one chosen option for an open Command.

  The idempotency key is a hash of the provider tool-call identity and the Command id, so a
  provider retry of the same call cannot answer twice, and no provider identifier reaches the
  host. Every failure becomes neutral text; the host's reason term never enters the result.
  """

  alias VoiceConverse.Ports

  @key_prefix "vc_answer_"
  @key_namespace "voice_converse/answer_command"

  @answered "Command answered."
  @stale "That Command is no longer open."
  @invalid "That is not one of this Command's options."
  @unavailable "Command answers unavailable."

  @stale_reasons [:stale, :conflict, :already_answered, :closed, :resolved]
  @invalid_reasons [:invalid_choice, :invalid_option, :unknown_option, :invalid_argument]

  @doc "The strict provider schema for selecting one Command option."
  @spec spec() :: VoiceConverse.Provider.tool_spec()
  def spec do
    %{
      name: "answer_command",
      description: "Answer an open operator Command. Pass the Command id and the exact option the operator chose.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 200,
            "description" => "Command id from list_open_commands."
          },
          "choice" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 500,
            "description" => "The option the operator selected, exactly as listed."
          }
        },
        "required" => ["id", "choice"],
        "additionalProperties" => false
      }
    }
  end

  @doc """
  Submits `choice` for one Command through `source.answer/4` under the `:answer` deadline.

  Returns neutral text either way; `{:error, text}` marks a refusal or an unavailable port.
  """
  @spec answer(module(), term(), term(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def answer(source, target, call_id, params) do
    with {:ok, id} <- command_id(params),
         {:ok, choice} <- choice(params) do
      key = idempotency_key(call_id, id)

      case Ports.call_port(source, :answer, [target, id, choice, key], :answer) do
        :ok -> {:ok, @answered}
        {:ok, _accepted} -> {:ok, @answered}
        {:error, reason} -> refusal(reason)
        _other -> {:error, @unavailable}
      end
    end
  end

  @doc """
  A stable, non-secret key for one provider tool call against one Command.

  The same call id and Command id always produce the same key, so a re-delivered tool call is a
  replay rather than a second answer. The raw provider identifier is hashed, never forwarded.
  """
  @spec idempotency_key(term(), term()) :: String.t()
  def idempotency_key(call_id, command_id) do
    digest = :crypto.hash(:sha256, Enum.join([@key_namespace, identity(call_id), identity(command_id)], "\n"))
    @key_prefix <> Base.url_encode64(digest, padding: false)
  end

  defp refusal(reason) do
    cond do
      reason in @stale_reasons or match?({:conflict, _}, reason) -> {:error, @stale}
      reason in @invalid_reasons or match?({:invalid_choice, _}, reason) -> {:error, @invalid}
      true -> {:error, @unavailable}
    end
  end

  defp command_id(params), do: field(params, "id", :id, 200)
  defp choice(params), do: field(params, "choice", :choice, 500)

  defp field(params, string_key, atom_key, max) when is_map(params) do
    case Map.get(params, string_key, Map.get(params, atom_key)) do
      value when is_binary(value) -> bounded(value, max)
      _missing -> {:error, @invalid}
    end
  end

  defp field(_params, _string_key, _atom_key, _max), do: {:error, @invalid}

  defp bounded(value, max) do
    value = String.trim(value)
    if value != "" and String.length(value) <= max, do: {:ok, value}, else: {:error, @invalid}
  end

  defp identity(value) when is_binary(value), do: value
  defp identity(value), do: inspect(value)
end
