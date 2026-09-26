# Host strings someone else chose, each carrying a terminal escape: a branch
# with a literal ESC title sequence, a remote and process names with the
# backslash forms `printf %b` would expand. Nothing here may reach the
# terminal as an escape (see the sanitization check in run.sh).
# shellcheck disable=SC2034
active_mcps=$'evil\e[2Jmcp \\033]0;mcp-title\\a'
cpu_usage=''
cron_count='0'
dev_ports='node\033[31m(3000)'
disk_pct=''
git_branch=$'feat/\e]0;pwned-title\a-x\\e[5m'
git_repo='own\033[2Jer/re\\epo'
mem_used_gb=''
ssh_count='0'
svc_panel=''
