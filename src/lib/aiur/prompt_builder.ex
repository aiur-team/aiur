defmodule Aiur.PromptBuilder do
  @moduledoc """
  Builds agent prompts from issue data.
  """

  alias Aiur.{CodingAgent, Config, Workflow}

  @render_opts [strict_filters: true, strict_variables: true]
  @shared_prompt_path Path.expand("../../prompts/shared-agent-instructions.md", __DIR__)
  @external_resource @shared_prompt_path
  @shared_prompt File.read!(@shared_prompt_path)

  @spec build_prompt(Aiur.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()
      |> ensure_utf8()

    shared_prompt_prefix() <> rendered_prompt <> complexity_suffix(issue)
  end

  # Appends the dev-configured guidance for the issue's complexity level
  # (agent.complexity_prompts) to the end of the rendered prompt. No label
  # or no configured string for that level leaves the prompt untouched.
  defp complexity_suffix(issue) do
    with level when is_integer(level) <- CodingAgent.complexity_level(issue),
         text when is_binary(text) <- Map.get(Config.agent_complexity_prompts(), level),
         trimmed when trimmed != "" <- String.trim(text) do
      "\n\n" <> trimmed
    else
      _ -> ""
    end
  end

  defp shared_prompt_prefix do
    case String.trim(@shared_prompt) do
      "" -> ""
      trimmed -> trimmed <> "\n\n"
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp ensure_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      # Replace invalid bytes so Jason.encode! won't crash
      :unicode.characters_to_binary(binary, :latin1, :utf8)
    end
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
