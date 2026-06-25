//go:build windows

package brain

import "strings"

// toErlangPath 把 Windows 路径转成 Erlang 可识别的形式。
//
// Erlang string literal 中反斜杠是转义字符 (\b=BS, \d=DEL, \e=ESC, \l=保留),
// Windows 路径的反斜杠会把路径损坏成乱码 (如 e:\bin\data -> e:[BS]in[DEL]ata),
// 导致 filelib:ensure_dir 等返回 {error, enoent}。
//
// 统一用正斜杠: Erlang file/filelib 模块在 Windows 上完整支持正斜杠路径。
func toErlangPath(p string) string {
	return strings.ReplaceAll(p, "\\", "/")
}
