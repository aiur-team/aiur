%{
  configs: [
    %{
      name: "default",
      checks: %{
        extra: [
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 200]}
        ]
      }
    }
  ]
}
