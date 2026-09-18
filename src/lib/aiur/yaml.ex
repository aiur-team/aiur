defmodule Aiur.Yaml do
  @moduledoc """
  YAML reads that never call `:application_controller`.

  `YamlElixir` runs `Application.start(:yamerl)` on *every* read. That is a
  synchronous controller call with no timeout, so any read made while the
  controller is busy stopping `:aiur` — a `terminate/2`, `prep_stop/1` or
  `stop/1` that resolves config with `Aiur.WorkflowStore` already down — never
  returns and wedges the controller for the rest of the VM (#2474, #2548).

  When yamerl is already running (always, once `:aiur` has booted) this parses
  through `:yamerl_constr` directly with the same options and mapping
  `YamlElixir` uses. Only a VM where yamerl was never started falls back to
  `YamlElixir`, whose start call is harmless there.
  """

  @yamerl_options [detailed_constr: true, str_node_as_binary: true, keep_duplicate_keys: true]

  @spec read_from_string(String.t()) :: {:ok, term()} | {:error, Exception.t()}
  def read_from_string(string) when is_binary(string) do
    if yamerl_running?(),
      do: read(fn options -> :yamerl_constr.string(string, options) end),
      else: YamlElixir.read_from_string(string)
  end

  @spec read_from_file(Path.t()) :: {:ok, term()} | {:error, Exception.t()}
  def read_from_file(path) when is_binary(path) do
    if yamerl_running?(),
      do: read(fn options -> :yamerl_constr.file(String.to_charlist(path), options) end),
      else: YamlElixir.read_from_file(path)
  end

  # A local registry lookup — deliberately not `Application.started_applications/0`,
  # which is itself a controller call.
  defp yamerl_running?, do: is_pid(Process.whereis(:yamerl_sup))

  defp read(construct) do
    options = Keyword.put(@yamerl_options, :one_result, true)
    {:ok, options |> construct.() |> List.last() |> YamlElixir.Mapper.process(options)}
  catch
    {:yamerl_exception, [{_, _, message, _, _, :file_open_failure, _, _}]} ->
      {:error, %YamlElixir.FileNotFoundError{message: List.to_string(message)}}

    {:yamerl_exception, [error | _]} ->
      {:error, YamlElixir.ParsingError.from_yamerl(error)}

    _, _ ->
      {:error, %YamlElixir.ParsingError{message: "malformed yaml"}}
  end
end
