defmodule Aiur.Init.Runtime do
  @moduledoc """
  Composition-root helpers for a live `aiur init` run (HTTP client start, toolchain detection, first warm-base build, config readback).
  """

  alias Aiur.Prewarm.Detect
  alias Aiur.RepoBase

  # `aiur init` boots interactively without the OTP app started, so the Req /
  # Finch HTTP client the GitHub label calls rely on isn't running yet. Start
  # it up front so a token-present run reaches tag creation instead of crashing.
  @spec ensure_http_client() :: :ok
  def ensure_http_client do
    Application.ensure_all_started(:req)
    :ok
  end

  @spec load_config(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_config(target) do
    case Aiur.Workflow.load(target) do
      {:ok, loaded} -> {:ok, loaded.config}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec detect_toolchain() :: Detect.result()
  def detect_toolchain, do: Detect.detect(File.cwd!())

  @spec run_first_prewarm(String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def run_first_prewarm(url, command) do
    RepoBase.refresh(RepoBase.base_path(url), url, command)
  end
end
