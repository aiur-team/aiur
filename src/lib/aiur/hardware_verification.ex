defmodule Aiur.HardwareVerification do
  @moduledoc """
  Detects acceptance criteria an agent sandbox cannot verify and owns the
  durable operator-verification marker names shared by dispatch and GitHub
  state transitions.
  """

  alias Aiur.Issue

  @required_suffix "operator-verification-required"
  @verified_suffix "operator-verified"
  @alerted_suffix "operator-verification-alerted"

  @signals [
    {:device_path, ~r{(?<!\w)/dev/(?:hidraw\d*|tty[[:alnum:]_.-]*|bus/usb(?:/[^\s`'"<>]*)?)}i},
    {:privileged_operation, ~r{\bsudo\b}i},
    {:udev, ~r{\budev(?:\s+(?:rule|rules|adm))?\b}i},
    {:system_service, ~r{\bsystemctl\b}i},
    {:physical_action, ~r{\b(?:unplug|replug|power[ -]?cycle|suspend/resume)\b}i},
    {:physical_action, ~r{\b(?:press|turn|touch)\s+(?:the\s+)?(?:dial|button|key)\b}i}
  ]

  @spec required_label(String.t()) :: String.t()
  def required_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@required_suffix}"

  @spec verified_label(String.t()) :: String.t()
  def verified_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@verified_suffix}"

  @spec alerted_label(String.t()) :: String.t()
  def alerted_label(prefix) when is_binary(prefix), do: "#{prefix}:#{@alerted_suffix}"

  @spec marker_suffix?(term()) :: boolean()
  def marker_suffix?(suffix) when is_binary(suffix),
    do: String.downcase(String.trim(suffix)) in [@required_suffix, @verified_suffix, @alerted_suffix]

  def marker_suffix?(_suffix), do: false

  @spec detected_signals(Issue.t() | map() | String.t() | term()) :: [atom()]
  def detected_signals(%Issue{} = issue), do: detected_signals([issue.title, issue.description])

  def detected_signals(%{} = issue),
    do: detected_signals([Map.get(issue, :title) || Map.get(issue, "title"), Map.get(issue, :description) || Map.get(issue, "body")])

  def detected_signals(text) when is_binary(text) do
    @signals
    |> Enum.flat_map(fn {signal, pattern} -> if Regex.match?(pattern, text), do: [signal], else: [] end)
    |> Enum.uniq()
  end

  def detected_signals(texts) when is_list(texts), do: texts |> Enum.filter(&is_binary/1) |> Enum.join("\n") |> detected_signals()
  def detected_signals(_input), do: []

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
    do: String.downcase(verified_label(prefix)) in label_names(issue_body)

  def operator_signed_off?(_issue_body, _prefix), do: false

  @doc "Whether an issue still needs operator verification before it can unblock a dependent."
  @spec unresolved?(map(), String.t()) :: boolean()
  def unresolved?(issue_body, prefix) when is_map(issue_body) and is_binary(prefix),
    do: signoff_required?(issue_body, prefix) and not operator_signed_off?(issue_body, prefix)

  def unresolved?(_issue_body, _prefix), do: false

  @spec verify_terminal_transition(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def verify_terminal_transition(issue_body, state_name, prefix) do
    if terminal_state?(state_name) and unresolved?(issue_body, prefix) do
      {:error, {:operator_signoff_required, %{required_label: required_label(prefix), verified_label: verified_label(prefix), signals: detected_signals(issue_body)}}}
    else
      :ok
    end
  end

  defp terminal_state?(state_name) when is_binary(state_name),
    do: String.downcase(String.trim(state_name)) in ["done", "cancelled", "canceled"]

  defp terminal_state?(_state_name), do: false

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
