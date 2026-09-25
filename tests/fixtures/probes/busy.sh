# Canned host-probe readings for a busy Linux server, seeded into the probe
# cache so a test render never runs top/df/ss/who/crontab/git/pgrep/systemctl.
# Sourced by tests/run.sh, which serialises every PROBE_VARS entry with
# `printf %q` exactly as agentline.sh does. $svc_panel keeps its escapes in
# backslash form, as the real probe stores them (printf %b renders them later).
# shellcheck disable=SC2034
active_mcps='context7 · playwright'
cpu_usage='37%'
cron_count='5'
dev_ports='node(3000) vite(5173) python3(8000) postgres(5432) redis-server(6379)'
disk_pct='41'
git_branch='main'
git_repo='OFCode-dev/agentline'
mem_used_gb='6.2G'
ssh_count='2'
svc_panel='\033[2mWeb ✓\033[0m \033[2m·\033[0m \033[1;31mDB ✗\033[0m \033[2m·\033[0m \033[2mCache ✓\033[0m'
