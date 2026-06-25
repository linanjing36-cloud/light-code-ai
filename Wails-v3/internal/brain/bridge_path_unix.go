//go:build !windows

package brain

// toErlangPath 在非 Windows 平台上原样返回路径。
// Unix 路径分隔符已经是 /, 且 Erlang string literal 中 / 不是转义字符,
// 无需任何转换。
func toErlangPath(p string) string {
	return p
}
