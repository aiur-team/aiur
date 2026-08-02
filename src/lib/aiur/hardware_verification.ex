defmodule Aiur.HardwareVerification do
  @moduledoc """
  Detects acceptance criteria an agent sandbox cannot verify and owns the
  durable operator-verification marker names shared by dispatch and GitHub
  state transitions.
  """

  alias Aiur.{Issue, Tracker}

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
    {:physical_action, ~r{\b(?:unplug(?:ged|ging)?|replug(?:ged|ging)?|power[ -]?cycle|suspend/resume)\b}i},
    {:physical_action, ~r{\b(?:press(?:ed|ing)?|turn(?:ed|ing)?|touch(?:ed|ing)?)\s+(?:the\s+)?(?:dial|button|key)\b}i}
  ]

  @non_execution_action ~r/^(?:add|build|create|document|remove|update)\b/i
  @simulated_context ~r/\b(?:mock|emulat(?:e|or|ion)|simulat(?:e|ion))\b/i
  @negated_operation ~r/\b(?:do\s+not|don't|never|without)\b/i
  @physical_execution ~r/\b(?:access|connect|enumerat|press|read|replug|resume|run|suspend|touch|turn|unplug|use|verify|write)\b/i

  @spec required_label(String.t()) :: String.t()
  def required_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@required_suffix}"

  @spec verified_label(String.t()) :: String.t()
  def verified_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@verified_suffix}"

  @spec passed_label(String.t()) :: String.t()
  def passed_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@passed_suffix}"

  @spec no_go_label(String.t()) :: String.t()
  def no_go_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@no_go_suffix}"

  @doc "Revokes a prior operator outcome when new verification evidence is required."
  @spec invalidate_operator_signoff(String.t(), String.t(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  def invalidate_operator_signoff(issue_id, prefix, remove_label \\ &Tracker.remove_label/2)
      when is_binary(issue_id) and is_binary(prefix) and is_function(remove_label, 2) do
    [verified_label(prefix), passed_label(prefix), no_go_label(prefix)]
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case remove_label.(issue_id, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:invalid_label_removal_result, other}}}
      end
    end)
  end

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
    do:
      not signoff_required?(issue_body, prefix) or
        (outcome_label(issue_body, prefix) == passed_label(prefix) and
           Map.get(issue_body, :operator_signoff_valid?, Map.get(issue_body, "operator_signoff_valid?", false)) == true)

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
      terminal_outcome_result(outcome_label(issue_body, prefix), issue_body, state_name, prefix)
    else
      :ok
    end
  end

  defp terminal_outcome_result(nil, issue_body, _state_name, prefix),
    do: {:error, {:operator_signoff_required, outcome_detail(issue_body, prefix)}}

  defp terminal_outcome_result(outcome, issue_body, state_name, prefix) do
    if outcome == passed_label(prefix) or cancellation_state?(state_name) do
      :ok
    else
      {:error, {:operator_no_go_requires_cancellation, outcome_detail(issue_body, prefix)}}
    end
  end

  @spec outcome_label(map(), String.t()) :: String.t() | nil
  def outcome_label(issue_body, prefix) when is_map(issue_body) and is_binary(prefix) do
    labels = label_names(issue_body)
    verified? = String.downcase(verified_label(prefix)) in labels
    passed? = String.downcase(passed_label(prefix)) in labels
    no_go? = String.downcase(no_go_label(prefix)) in labels

    cond do
      verified? and passed? and not no_go? -> passed_label(prefix)
      verified? and no_go? and not passed? -> no_go_label(prefix)
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
      |> Enum.reduce({false, []}, fn line, {in_verification, criteria} ->
        trimmed = String.trim(line)

        cond do
          verification_heading?(trimmed) ->
            {true, criteria}

          Regex.match?(~r/^[#]{1,6}\s+/, trimmed) ->
            {false, criteria}

          in_verification and criterion_line?(trimmed) ->
            {true, [trimmed | criteria]}

          true ->
            {in_verification, criteria}
        end
      end)

    Enum.reverse(criteria)
  end

  defp match_criterion(line) do
    for clause <- criterion_clauses(line),
        physical_execution?(clause),
        {signal, pattern} <- @signals,
        Regex.match?(pattern, clause),
        do: %{signal: signal, evidence: line, operator_action: "Verify this criterion on the physical device."}
  end

  defp verification_heading?(line) do
    Regex.match?(~r/^[#]{1,6}\s+(?:acceptance(?:\s+criteria)?|(?:hardware\s+)?verification|spike(?:\s+sequence)?|(?:sub-)?check)\b/i, line)
  end

  defp criterion_line?(line), do: Regex.match?(~r/^(?:[-*+]\s+|\d+[.)]\s+|\[[ xX]\]\s+)/, line)

  defp criterion_clauses(line) do
    criterion = Regex.replace(~r/^(?:[-*+]\s+|\d+[.)]\s+|\[[ xX]\]\s+)/, line, "")

    Regex.split(~r/(?:[;.!?]+|\b(?:but|however|then|while)\b)/i, criterion, trim: true)
  end

  defp physical_execution?(clause) do
    not documentation_only?(clause) and
      not Regex.match?(@simulated_context, clause) and
      not negated_execution?(clause)
  end

  defp documentation_only?(clause) do
    trimmed = String.trim(clause)

    Regex.match?(~r/^document\s+how\s+to\b/i, trimmed) or
      (Regex.match?(@non_execution_action, trimmed) and
         not Regex.match?(@physical_execution, clause))
  end

  defp negated_execution?(clause) do
    Regex.match?(~r/\bsudo\s+is\s+not\s+available\b/i, clause) or
      (Regex.match?(@negated_operation, clause) and
         not Regex.match?(~r/\b(?:not|never)\s+(?:available|working|responding)\b/i, clause))
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
