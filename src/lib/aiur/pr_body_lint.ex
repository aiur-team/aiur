defmodule Aiur.PrBodyLint do
  @moduledoc "Lints a PR body against the repository PR template and its Local tests evidence; `mix pr_body.check` and the handoff guard share it."

  alias Aiur.LocalTestEvidence

  @doc "Every template and Local tests error in `body`; `opts` takes `:policy` and `:head`."
  @spec errors(String.t(), String.t(), keyword()) :: [String.t()]
  def errors(template, body, opts \\ []), do: lint(template, body, headings(template)) ++ evidence_errors(body, opts)

  @doc "The template's markdown headings, in order."
  @spec headings(String.t()) :: [String.t()]
  def headings(template), do: Regex.scan(~r/^\#{2,6}\s+.+$/m, template) |> Enum.map(&hd/1)

  defp evidence_errors(body, opts) do
    with {:ok, evidence} <- LocalTestEvidence.parse(body),
         :ok <- LocalTestEvidence.validate(evidence, opts[:policy] || "none", opts[:head]) do
      []
    else
      :missing -> ["Missing required heading: ## Local tests"]
      {:error, message} -> [message]
    end
  end

  defp lint(template, body, headings) do
    []
    |> check_required_headings(body, headings)
    |> check_order(body, headings)
    |> check_no_placeholders(body)
    |> check_sections_from_template(template, body, headings)
  end

  defp check_required_headings(errors, body, headings) do
    missing = Enum.filter(headings, fn heading -> heading_position(body, heading) == :nomatch end)
    errors ++ Enum.map(missing, fn heading -> "Missing required heading: #{heading}" end)
  end

  defp check_order(errors, body, headings) do
    positions =
      headings
      |> Enum.map(&heading_position(body, &1))
      |> Enum.reject(&(&1 == :nomatch))

    if positions == Enum.sort(positions), do: errors, else: errors ++ ["Required headings are out of order."]
  end

  defp check_no_placeholders(errors, body) do
    if String.contains?(body, "<!--") do
      errors ++ ["PR description still contains template placeholder comments (<!-- ... -->)."]
    else
      errors
    end
  end

  defp check_sections_from_template(errors, template, body, headings) do
    Enum.reduce(headings, errors, fn heading, acc ->
      template_section = capture_heading_section(template, heading, headings)
      body_section = capture_heading_section(body, heading, headings)

      cond do
        is_nil(body_section) ->
          acc

        String.trim(body_section) == "" ->
          acc ++ ["Section cannot be empty: #{heading}"]

        true ->
          acc
          |> maybe_require_bullets(heading, template_section, body_section)
          |> maybe_require_checkboxes(heading, template_section, body_section)
      end
    end)
  end

  defp maybe_require_bullets(errors, heading, template_section, body_section) do
    requires_bullets = Regex.match?(~r/^- /m, template_section || "")

    if requires_bullets and not Regex.match?(~r/^- /m, body_section) do
      errors ++ ["Section must include at least one bullet item: #{heading}"]
    else
      errors
    end
  end

  defp maybe_require_checkboxes(errors, heading, template_section, body_section) do
    requires_checkboxes = Regex.match?(~r/^- \[ \] /m, template_section || "")

    if requires_checkboxes and not Regex.match?(~r/^- \[[ xX]\] /m, body_section) do
      errors ++ ["Section must include at least one checkbox item: #{heading}"]
    else
      errors
    end
  end

  defp heading_position(body, heading) do
    case :binary.match(body, heading) do
      {idx, _len} -> idx
      :nomatch -> :nomatch
    end
  end

  defp capture_heading_section(doc, heading, headings) do
    with {heading_idx, _} <- :binary.match(doc, heading),
         section_start <- heading_idx + byte_size(heading),
         true <- section_start + 2 <= byte_size(doc),
         "\n\n" <- binary_part(doc, section_start, 2) do
      extract_section_content(doc, section_start + 2, heading, headings)
    else
      :nomatch -> nil
      false -> ""
      _ -> nil
    end
  end

  defp extract_section_content(doc, content_start, heading, headings) do
    content = binary_part(doc, content_start, byte_size(doc) - content_start)

    case next_heading_offset(content, heading, headings) do
      nil -> content
      offset -> binary_part(content, 0, offset)
    end
  end

  defp next_heading_offset(content, heading, headings) do
    headings_after(heading, headings)
    |> Enum.map(fn marker -> :binary.match(content, marker) end)
    |> Enum.filter(&(&1 != :nomatch))
    |> Enum.map(fn {idx, _} -> idx end)
    |> case do
      [] -> nil
      indexes -> Enum.min(indexes)
    end
  end

  defp headings_after(current_heading, headings) do
    headings
    |> Enum.filter(&(&1 != current_heading))
    |> Enum.map(&("\n" <> &1))
  end
end
