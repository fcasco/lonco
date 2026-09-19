#!/usr/bin/env bash
# tests/test_extract_code_notice.sh — bin/shellm extract_code behavior, and the
# stderr notice it prepends when a reply has no bash code block.
#
# Usage: tests/test_extract_code_notice.sh
#
# When a model reply has no ```bash block, shellm runs the whole reply as a
# shell command (the no-fence fallback). That is almost always the model ending
# its turn with a plain sentence, which fails "command not found" and, on a
# weaker model, repeats until the run is killed as a stall (Nemotron on idle
# wakes, 2026-09-05). extract_code now prepends a notice — captured on stderr
# and shown back to the model next turn — that says the reply ran as a command
# and how to end a run (FINAL= inside a bash block). This test loads extract_code
# out of bin/shellm and checks the notice fires only for bare prose with real
# content.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# Load just extract_code from bin/shellm. Source from a temp file, not
# `source <(...)`: the CI macOS bash 3.2 binary has no process substitution.
FN=$(mktemp)
trap 'rm -f "$FN"' EXIT
sed -n '/^extract_code() {/,/^}/p' "$REPO/bin/shellm" > "$FN"
# shellcheck disable=SC1090
source "$FN"

NOTICE='shellm: your reply had no'   # start of the prepended notice line

# Bare prose: notice prepended, and the prose is still present as code.
out=$(extract_code "Idle — nothing to do now.")
grep -q "$NOTICE" <<<"$out" && ok "bare prose gets the no-fence notice" || bad "bare prose notice" "$out"
grep -q 'Idle — nothing to do now\.' <<<"$out" && ok "the prose is still passed through as code" || bad "prose passthrough"
grep -q 'FINAL=' <<<"$out" && ok "the notice tells the model how to end a run (FINAL=)" || bad "notice mentions FINAL="

# A fenced block: no notice, just the code.
out=$(extract_code "Let me look.
\`\`\`bash
ls -la
\`\`\`")
grep -q "$NOTICE" <<<"$out" && bad "a fenced reply must not get the notice" || ok "a fenced reply gets no notice"
[[ "$(printf '%s' "$out")" == "ls -la" ]] && ok "a fenced reply extracts just its code" || bad "fenced extract" "$out"

# A clean FINAL= block: no notice.
out=$(extract_code "\`\`\`bash
FINAL=\"done\"
\`\`\`")
grep -q "$NOTICE" <<<"$out" && bad "a FINAL= block must not get the notice" || ok "a FINAL= block gets no notice"

# Whitespace-only reply: no notice (empty code is treated as a final upstream).
out=$(extract_code "   ")
grep -q "$NOTICE" <<<"$out" && bad "a blank reply must not get the notice" || ok "a blank reply gets no notice"

# A fence appended to the end of a prose line (grok style) still counts as fenced.
out=$(extract_code "do it now.\`\`\`bash
echo hi
\`\`\`")
grep -q "$NOTICE" <<<"$out" && bad "an end-of-line fence must not get the notice" || ok "an end-of-line fence gets no notice"

# ── <tool_call> markup (recursive-LM tool calls) ────────────────────────────
# A reply in <tool_call> markup names the tool to invoke. shellm's one tool is
# bash, so a `shellm` call with a `command` argument is executed directly.
# Before this, the whole reply (markup and prose) fell through to the no-fence
# fallback and ran as a shell command, failing "command not found".
TC_NOTICE='your <tool_call> shellm command was executed directly'

# Full tool_call reply (prose first, then the call): the command runs; the
# prose and markup never get executed as bash.
out=$(extract_code 'I will check this machine.
<tool_call>
shellm
<arg_key>command</arg_key>
<arg_value>which python3 curl jq 2>/dev/null</arg_value>
</tool_call>')
grep -q "$TC_NOTICE" <<<"$out" && ok "a <tool_call> shellm reply is recognized" || bad "tool_call recognition" "$out"
grep -q 'which python3 curl jq 2>/dev/null' <<<"$out" && ok "the tool_call command is extracted to run" || bad "tool_call command extract" "$out"
grep -q "$NOTICE" <<<"$out" && bad "a tool_call reply must not get the no-fence notice" || ok "a tool_call reply gets no no-fence notice"

# Inline one-line tool_call with a multi-line command: newlines preserved.
out=$(extract_code '<tool_call>shellm<arg_key>command</arg_key><arg_value>echo one
echo two</arg_value></tool_call>')
n=$(printf '%s\n' "$out" | grep -c '^echo ')
[[ "$n" -eq 2 ]] && ok "a multi-line tool_call command keeps its newlines" || bad "multiline command" "$out"

# A call to a tool shellm cannot run is not executed as bash; a stub notice
# answers instead so the model learns which tools exist.
out=$(extract_code '<tool_call>
write_file
<arg_key>path</arg_key>
<arg_value>/tmp/x</arg_value>
</tool_call>')
grep -q 'not a call shellm can run' <<<"$out" && ok "a foreign-tool call gets a cannot-run notice" || bad "foreign tool notice" "$out"
grep -q 'write_file' <<<"$out" && bad "foreign tool markup must not be run as bash" || ok "foreign tool markup is not executed"

# ── extract_reasoning stops at tool-call markup ─────────────────────────────
RN=$(mktemp)
trap 'rm -f "$FN" "$RN"' EXIT
sed -n '/^extract_reasoning() {/,/^}/p' "$REPO/bin/shellm" > "$RN"
# shellcheck disable=SC1090
source "$RN"

th=$(extract_reasoning 'I will check the machine.
<tool_call>
shellm
<arg_key>command</arg_key>
<arg_value>x</arg_value>
</tool_call>')
grep -q 'I will check the machine\.' <<<"$th" && ok "reasoning keeps the prose before a tool_call" || bad "reasoning prose" "$th"
grep -q 'tool_call\|arg_key\|arg_value' <<<"$th" && bad "reasoning must not include tool-call markup" || ok "reasoning excludes tool-call markup"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
