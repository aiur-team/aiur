defmodule Aiur.Config.NetlifySchemaTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema

  test "Netlify config defaults remain disabled and poll every fifteen minutes" do
    assert {:ok, config} = Schema.parse(%{})
    assert config.netlify.enabled == false
    assert config.netlify.poll_seconds == 900
    assert config.netlify.credit_alert_threshold == 0
  end

  test "invalid Netlify polling and negative threshold values are rejected" do
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"netlify" => %{"poll_seconds" => 1}})
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"netlify" => %{"credit_alert_threshold" => -1}})
  end
end
