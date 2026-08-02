defmodule Aiur.OpenAICompat.Transport do
  @moduledoc false

  alias Aiur.OpenAICompat.Concurrency

  @spec complete(map(), [map()], [map()]) :: {:ok, map()} | {:error, term()}
  def complete(config, messages, tools) do
    request = build_request(config, messages, tools)

    {result, in_flight} = request(config, request)

    with {:ok, response} <- result,
         :ok <- status(response),
         {:ok, completion} <- decode(config.transport, response) do
      {:ok,
       completion
       |> Map.put(:headers, Map.get(response, :headers, %{}))
       |> Map.put(:local_in_flight, in_flight)}
    end
  end

  defp request(%{quirks: %{local_concurrency_limit: true}} = config, request) do
    Concurrency.with_slot(config.backend, fn -> config.request_fun.(request) end)
  end

  defp request(config, request), do: {config.request_fun.(request), nil}

  defp build_request(%{transport: :chat_completions} = config, messages, tools) do
    %{
      method: :post,
      url: endpoint(config.base_url, "/chat/completions"),
      headers: request_headers(config),
      json: %{"model" => config.model, "messages" => messages, "tools" => tools, "tool_choice" => "auto"}
    }
  end

  defp build_request(%{transport: :responses} = config, messages, tools) do
    %{
      method: :post,
      url: endpoint(config.base_url, "/responses"),
      headers: request_headers(config),
      json: %{"model" => config.model, "input" => messages, "tools" => tools}
    }
  end

  defp request_headers(config) do
    %{"authorization" => "Bearer #{config.api_key}", "content-type" => "application/json"}
    |> maybe_put_openrouter_headers(config)
  end

  defp maybe_put_openrouter_headers(headers, %{quirks: %{openrouter_metadata: true}}),
    do: Map.put(headers, "x-openrouter-metadata", "enabled")

  defp maybe_put_openrouter_headers(headers, _config), do: headers

  defp endpoint(base, suffix), do: String.trim_trailing(base, "/") <> suffix

  defp status(%{status: status}) when status in 200..299, do: :ok
  defp status(%{status: 401}), do: {:error, :unauthorized}
  defp status(%{status: 429}), do: {:error, :rate_limited}
  defp status(%{status: status, body: body}), do: {:error, {:http_error, status, safe_error(body)}}
  defp status(_), do: {:error, :invalid_response}

  defp decode(:chat_completions, %{body: body}) when is_map(body) do
    with [choice | _] <- body["choices"],
         message when is_map(message) <- choice["message"] do
      {:ok,
       %{
         id: body["id"],
         model: selected_model(body) || body["model"],
         provider: selected_provider(body) || body["provider"],
         message: message,
         text: message["content"],
         reasoning: message["reasoning_content"],
         tool_calls: normalize_chat_tool_calls(message["tool_calls"]),
         finish_reason: choice["finish_reason"],
         usage: body["usage"]
       }}
    else
      _ -> {:error, :invalid_chat_completion}
    end
  end

  defp decode(:responses, %{body: body}) when is_map(body) do
    output = List.wrap(body["output"])

    message = Enum.find(output, &(&1["type"] == "message")) || %{}
    content = List.wrap(message["content"])
    text = content |> Enum.filter(&(&1["type"] in ["output_text", "text"])) |> Enum.map_join("", &(&1["text"] || ""))
    reasoning = output |> Enum.filter(&(&1["type"] == "reasoning")) |> Enum.map_join("\n", &reasoning_text/1)

    tool_calls =
      output
      |> Enum.filter(&(&1["type"] in ["function_call", "tool_call"]))
      |> Enum.map(fn call -> %{id: call["call_id"] || call["id"], name: call["name"], arguments: call["arguments"]} end)

    {:ok,
     %{
       id: body["id"],
       model: selected_model(body) || body["model"],
       provider: selected_provider(body) || body["provider"],
       output: output,
       message: %{"role" => "assistant", "content" => text},
       text: text,
       reasoning: reasoning,
       tool_calls: tool_calls,
       finish_reason: body["status"],
       usage: body["usage"]
     }}
  end

  defp decode(_, _), do: {:error, :invalid_response_body}

  defp normalize_chat_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      function = call["function"] || %{}
      %{id: call["id"], name: function["name"], arguments: function["arguments"]}
    end)
  end

  defp normalize_chat_tool_calls(_), do: []

  defp reasoning_text(item) do
    item["summary"]
    |> List.wrap()
    |> Enum.map_join("\n", fn part -> part["text"] || "" end)
  end

  defp selected_model(body) do
    case selected_endpoint(body) do
      %{"model" => model} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  defp selected_provider(body) do
    case selected_endpoint(body) do
      %{"provider" => provider} when is_binary(provider) and provider != "" -> provider
      _ -> nil
    end
  end

  defp selected_endpoint(body) do
    body
    |> get_in(["openrouter_metadata", "endpoints", "available"])
    |> List.wrap()
    |> Enum.find(&(&1["selected"] == true))
  end

  defp safe_error(%{"error" => %{"message" => message}}) when is_binary(message) do
    message |> String.slice(0, 500) |> Aiur.SecretRedactor.redact()
  end

  defp safe_error(_), do: "provider request failed"
end
