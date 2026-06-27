package capability

func Normalize(desc Desc) Desc {
	if desc.Kind == "" {
		desc.Kind = KindTool
	}
	if desc.Source == "" {
		desc.Source = "builtin"
	}
	if desc.Version == "" {
		desc.Version = "v1"
	}
	if desc.RiskLevel == "" {
		desc.RiskLevel = RiskSafe
	}
	if desc.CostHint == "" {
		desc.CostHint = CostLow
	}
	if len(desc.Tags) == 0 {
		desc.Tags = []string{string(desc.Kind)}
	}
	return desc
}

func NewToolDesc(name, description, inputSchema string, tags ...string) Desc {
	return Normalize(Desc{
		Name:        name,
		Kind:        KindTool,
		Source:      "builtin",
		Version:     "v1",
		Description: description,
		InputSchema: inputSchema,
		Streaming:   false,
		RiskLevel:   RiskSafe,
		CostHint:    CostLow,
		Tags:        tags,
	})
}
