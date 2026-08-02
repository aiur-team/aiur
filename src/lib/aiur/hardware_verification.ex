defmodule Aiur.HardwareVerification do
  @moduledoc """
  Detects acceptance criteria an agent sandbox cannot verify and owns the
  durable operator-verification marker names shared by dispatch and GitHub
  state transitions.
  """

  alias Aiur.Issue

  @required_suffix "operator-verification-required"
  @verified_suffix "operator-verified"
  @passed_suffix "operator-verification-passed"
  @no_go_suffix "operator-verification-no-go"
  @alerted_suffix "operator-verification-alerted"

  @signals [
    {:device_path, ~r{(?<!\w)/dev/(?:hidraw\d*|tty[[:alnum:]_.-]*|bus/usb(?:/[^\s`'"<>]*)?)}i},
    {:privileged_operation, ~r{\bsudo\b}i},
    {:udev, ~r{\budev(?:\s+(?:rule|rules|adm))?\b}i},
    {:system_service, ~r{\bsystemctl\b}i},
    {:physical_action, ~r{\b(?:unplug|replug|power[ -]?cycle|suspend/resume)\b}i},
    {:physical_action, ~r{\b(?:press|turn|touch)\s+(?:the\s+)?(?:dial|button|key)\b}i}
  ]

  @non_execution_context ~r/\b(?:mock|emulat(?:e|or|ion)|simulat(?:e|ion)|docs?|document(?:ation)?|remove|without|not\s+(?:run|use|access)|do\s+not|don't)\b/i

  @spec required_label(String.t()) :: String.t()
  def required_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@required_suffix}"

  @spec verified_label(String.t()) :: String.t()
  def verified_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@verified_suffix}"

  @spec passed_label(String.t()) :: String.t()
  def passed_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@passed_suffix}"

  @spec no_go_label(String.t()) :: String.t()
  def no_go_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@no_go_suffix}"

  @spec alerted_label(String.t()) :: String.t()
  def alerted_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@alerted_suffix}"

  @spec marker_suffix?(term()) :: boolean()
  def marker_suffix?(suffix) when is_binary(suffix),
    do: String.downcase(String.trim(suffix)) in [@required_suffix, @verified_suffix, @passed_suffix, @no_go_suffix, @alerted_suffix]

  def marker_suffix?(_suffix), do: false

  @type criterion :: %{signal: atom(), evidence: String.t(), operator_action: String.t()}

  @spec matched_criteria(Issue.t() | map() | String.t() | term()) :: [criterion()]
  def matched_criteria(%Issue{} = issue), do: matched_criteria(issue.description)

  def matched_criteria(%{} = issue), do: matched_criteria(Map.get(issue, :description) || Map.get(issue, "body"))

  def matched_criteria(text) when is_binary(text) do
    text
    |> acceptance_criteria()
    |> Enum.flat_map(&match_criterion/1)
  end

  def matched_criteria(_input), do: []

  @spec detected_signals(Issue.t() | map() | String.t() | term()) :: [atom()]
  def detected_signals(input), do: input |> matched_criteria() |> Enum.map(& &1.signal) |> Enum.uniq()

  @spec required?(Issue.t() | map() | String.t() | term()) :: boolean()
  def required?(input), do: detected_signals(input) != []

  @spec signoff_required?(map(), String.t()) :: boolean()
  def signoff_required?(issue_body, prefix) when is_map(issue_body) and is_binary(prefix) do
    labels = label_names(issue_body)
    required?(issue_body) or String.downcase(required_label(prefix)) in labels
  end

  def signoff_required?(_issue_body, _prefix), do: false

  @spec operator_signed_off?(map(), String.t()) :: boolean()
  def operator_signed_off?(issue_body, prefix) when is_map(issue_body) and is_binary(prefix),
    do: outcome_label(issue_body, prefix) != nil

  def operator_signed_off?(_issue_body, _prefix), do: false

  @doc "Whether an issue still needs an operator outcome before it can finish."
  @spec unresolved?(map(), String.t()) :: boolean()
  def unresolved?(issue_body, prefix) when is_map(issue_body) and is_binary(prefix),
    do: signoff_required?(issue_body, prefix) and not operator_signed_off?(issue_body, prefix)

  def unresolved?(_issue_body, _prefix), do: false

  @doc "Whether a terminal hardware blocker has an explicit passing outcome."
  @spec dependency_resolved?(map(), String.t()) :: boolean()
  def dependency_resolved?(issue_body, prefix) when is_map(issue_body) and is_binary(prefix),
    do: not signoff_required?(issue_body, prefix) or outcome_label(issue_body, prefix) == passed_label(prefix)

  def dependency_resolved?(_issue_body, _prefix), do: false

  @spec verify_terminal_transition(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def verify_terminal_transition(issue_body, state_name, prefix) do
    verify_terminal_outcome(issue_body, state_name, prefix)
  end

  defp terminal_state?(state_name) when is_binary(state_name),
    do: String.downcase(String.trim(state_name)) in ["done", "cancelled", "canceled"]

  defp terminal_state?(_state_name), do: false

  defp cancellation_state?(state_name) when is_binary(state_name),
    do: String.downcase(String.trim(state_name)) in ["cancelled", "canceled"]

  defp cancellation_state?(_state_name), do: false

  defp verify_terminal_outcome(issue_body, state_name, prefix) do
    if terminal_state?(state_name) and signoff_required?(issue_body, prefix) do
      case outcome_label(issue_body, prefix) do
        nil ->
          {:error, {:operator_signoff_required, outcome_detail(issue_body, prefix)}}

        outcome ->
          cond do
            outcome == passed_label(prefix) -> :ok
            cancellation_state?(state_name) -> :ok
            true -> {:error, {:operator_no_go_requires_cancellation, outcome_detail(issue_body, prefix)}}
          end
      end
    else
      :ok
    end
  end

  @spec outcome_label(map(), String.t()) :: String.t() | nil
  def outcome_label(issue_body, prefix) when is_map(issue_body) and is_binary(prefix) do
    labels = label_names(issue_body)

    cond do
      String.downcase(passed_label(prefix)) in labels -> passed_label(prefix)
      String.downcase(no_go_label(prefix)) in labels -> no_go_label(prefix)
      true -> nil
    end
  end

  def outcome_label(_issue_body, _prefix), do: nil

  defp outcome_detail(issue_body, prefix) do
    %{
      required_label: required_label(prefix),
      verified_label: verified_label(prefix),
      passed_label: passed_label(prefix),
      no_go_label: no_go_label(prefix),
      criteria: matched_criteria(issue_body)
    }
  end

  defp acceptance_criteria(text) do
    {_, criteria} =
      text
      |> String.split("\n")
      |> Enum.reduce({false, []}, fn line, {in_acceptance, criteria} ->
        trimmed = String.trim(line)

        cond do
          Regex.match?(~r/^[#]{1,6}\s*acceptance(?:\s+criteria)?\s*:?[[:space:]]*$/i, trimmed) ->
            {true, criteria}

          Regex.match?(~r/^[#]{1,6}\s+/, trimmed) ->
            {false, criteria}

          in_acceptance and Regex.match?(~r/^(?:[-*+]\s+|\d+[.)]\s+|\[[ xX]\]\s+)/, trimmed) ->
            {true, [trimmed | criteria]}

          true ->
            {in_acceptance, criteria}
        end
      end)

    Enum.reverse(criteria)
  end

  defp match_criterion(line) do
    if Regex.match?(@non_execution_context, line) do
      []
    else
      @signals
      |> Enum.flat_map(fn {signal, pattern} ->
        if Regex.match?(pattern, line), do: [%{signal: signal, evidence: line, operator_action: "Verify this criterion on the physical device."}], else: []
      end)
    end
  end

  defp label_names(issue_body) do
    issue_body
    |> Map.get("labels", Map.get(issue_body, :labels, []))
    |> Enum.map(fn
      %{"name" => name} -> String.downcase(name)
      %{name: name} -> String.downcase(name)
      name when is_binary(name) -> String.downcase(name)
      _ -> ""
    end)
  end
end
