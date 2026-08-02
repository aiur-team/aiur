defmodule Aiur.PromptBuilder do
  @moduledoc """
  Builds agent prompts from issue data.
  """

  require Logger

  alias Aiur.{CodingAgent, Config, HardwareVerification, Workflow}

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

    shared_prompt_prefix() <>
      integration_branch_prompt(issue) <> rendered_prompt <> complexity_suffix(issue) <> hardware_verification_suffix(issue)
  end

  defp integration_branch_prompt(issue) do
    base_branch = Config.base_branch()

    Logger.info(
      "Authoritative integration branch: issue_id=#{inspect(issue.id)} " <>
        "issue_identifier=#{inspect(issue.identifier)} tracker.base_branch=#{inspect(base_branch)}"
    )

    """
    ## Authoritative integration branch

    This workflow's configured `tracker.base_branch` is `#{base_branch}`. The agent process exposes the same value as
    `AIUR_BASE_BRANCH`; it is authoritative even when the repository default differs. Create pull requests with
    `--base "$AIUR_BASE_BRANCH"`, never from `origin/HEAD`, and verify an existing pull request's base before CI
    handoff.

    """
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

  defp hardware_verification_suffix(issue) do
    if HardwareVerification.required?(issue) do
      verified = HardwareVerification.verified_label(Aiur.GitHub.Config.label_prefix())
      passed = HardwareVerification.passed_label(Aiur.GitHub.Config.label_prefix())
      no_go = HardwareVerification.no_go_label(Aiur.GitHub.Config.label_prefix())

      """

      ## Hardware-dependent acceptance criteria

      This ticket contains the following physical acceptance criteria that the sandbox and CI cannot verify:

      #{HardwareVerification.matched_criteria(issue) |> Enum.map_join("\n", fn criterion -> "- `#{criterion.signal}`: #{criterion.evidence}" end)}

      - Complete every software, emulator, CI, and Executor-testable criterion normally. Do not self-certify only the physical criteria listed above.
      - For every criterion you cannot verify, call `report_untestable` with the exact criterion and reason. It raises an operator alert and preserves the completion block.
      - State the CI blind spot prominently in the pull-request description so the operator knows human hardware verification is the remaining gate.
      - A configured human operator must apply `#{verified}` and then record `#{passed}` for a passing go decision or `#{no_go}` for a failed no-go decision. Aiur verifies the GitHub sign-off event. Only `#{passed}` can release dependents; a no-go can terminate the spike as cancelled.
      """
    else
      ""
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
