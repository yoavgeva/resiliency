%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        {Credo.Check.Design.AliasUsage, excluded_namespaces: ["Resiliency"]}
      ]
    }
  ]
}
