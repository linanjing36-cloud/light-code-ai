package memory

import "testing"

func TestEscapeTag(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{"test-session-1", `test\-session\-1`},
		{"plain", "plain"},
		{`a,b`, `a\,b`},
		{`x\y`, `x\\y`},
	}
	for _, tc := range tests {
		if got := escapeTag(tc.in); got != tc.want {
			t.Fatalf("escapeTag(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
