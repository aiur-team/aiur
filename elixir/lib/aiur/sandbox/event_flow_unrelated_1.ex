defmodule Aiur.Sandbox.EventFlowUnrelated1 do
  @moduledoc false
  # Sandbox file unrelated to the blocked/blocking chain; lives here so
  # the 3-ticket flow exercises a real workspace with files outside the
  # coordination dance. `aiur --test` does NOT touch this file.
end
