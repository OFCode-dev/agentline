# Host strings someone else chose, each carrying a terminal escape: a branch
# with a literal ESC title sequence, a remote and process names with the
# backslash forms `printf %b` would expand, and UTF-8 encoded C1 controls
# (U+009B CSI = C2 9B, U+009D OSC = C2 9D, U+0085 = C2 85), which bash's
# [[:cntrl:]] misses outside a UTF-8 locale and git allows in a ref name.
# Next to them, text that must survive: Turkish letters, an emoji and ©,
# whose encodings share bytes with the C1 range (ş = C5 9F, 🚀 = F0 9F 9A 80).
# Nothing here may reach the terminal as an escape (see the sanitization
# check in run.sh).
# shellcheck disable=SC2034
active_mcps=$'evil\e[2J\xc2\x9b2Jmcp \\033]0;mcp-title\\a'
cpu_usage=''
cron_count='0'
dev_ports=$'node\xc2\x9d\\033[31m(3000)'
disk_pct=''
git_branch=$'feat/\e]0;pwned-title\a-x\\e[5m\xc2\x9b31m-\xc5\x9f\xc4\x9f\xc3\x87\xf0\x9f\x9a\x80\xc2\xa9'
git_repo=$'own\\033[2Jer\xc2\x85/re\\\\epo'
mem_used_gb=''
ssh_count='0'
svc_panel=''
