# The busy host, in a repository with work in flight: two commits ahead of
# its upstream, one behind, three changed files, two untracked, one
# conflict. Sourced by tests/run.sh like busy.sh.
# shellcheck disable=SC2034
. "$(dirname "${BASH_SOURCE[0]}")/busy.sh"
git_ab='↑2↓1'
git_dirty='±3 ?2 ✖1'
