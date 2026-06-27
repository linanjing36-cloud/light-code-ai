package capability

type Kind string

const (
	KindTool   Kind = "tool"
	KindSkill  Kind = "skill"
	KindMCP    Kind = "mcp"
	KindPlugin Kind = "plugin"
)

type RiskLevel string

const (
	RiskSafe      RiskLevel = "safe"
	RiskReview    RiskLevel = "review"
	RiskDangerous RiskLevel = "dangerous"
)

type CostHint string

const (
	CostLow    CostHint = "low"
	CostMedium CostHint = "medium"
	CostHigh   CostHint = "high"
)

type Desc struct {
	Name         string
	Kind         Kind
	Source       string
	Version      string
	Description  string
	InputSchema  string
	OutputSchema string
	Streaming    bool
	RiskLevel    RiskLevel
	CostHint     CostHint
	Tags         []string
}
