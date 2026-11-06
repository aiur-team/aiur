defmodule Aiur.EpicCLI do
  @moduledoc """
  Deprecated name for `Aiur.LaneCLI`.

  `aiur epic set|clear|confirm` still work over the same override store and
  print a deprecation line naming `aiur lane`. `aiur epic show|list` keep their
  output until epic records replace them, so they route here too.
  """

  @spec run(keyword()) :: non_neg_integer()
  defdelegate run(opts), to: Aiur.LaneCLI
end
