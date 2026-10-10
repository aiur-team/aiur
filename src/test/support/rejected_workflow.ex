defmodule Aiur.TestSupport.RejectedWorkflow do
  @moduledoc false

  @reload_timeout_ms 15_000

  @doc """
  Writes a schema-invalid workflow fixture over the active config and returns
  the rejection `Aiur.WorkflowStore` answers the reload with.

  The store keeps the last known good config when a reload fails validation
  (#3961), so `Aiur.TestSupport.write_workflow_file!/2` cannot publish an
  invalid fixture. Validation tests assert on the returned
  `{:error, {:invalid_workflow_config, message}}` instead. A fixture the store
  accepts fails the match here.
  """
  @spec write_rejected_workflow_file!(Path.t(), keyword()) :: {:error, term()}
  def write_rejected_workflow_file!(path, overrides) do
    # A non-active path is only staged, never reloaded; the rename then lands the fixture as one unit.
    staged = path <> ".staged"
    :ok = Aiur.TestSupport.write_workflow_file!(staged, overrides)
    File.rename!(staged, path)

    {:error, _reason} = rejection = Aiur.WorkflowStore.force_reload(@reload_timeout_ms)
    rejection
  end
end
