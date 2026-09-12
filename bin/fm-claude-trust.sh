#!/usr/bin/env bash
# Pre-register Claude Code's workspace trust for the isolated task worktree a
# ship/scout spawn is about to launch a claude crewmate into, so the worker
# reaches its brief instead of wedging on the trust dialog.
#
# Usage: fm-claude-trust.sh <worktree> <project> [<home>]
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the project clone that worktree belongs to
#   <home>      the launching firstmate home (FM_HOME). Optional, and consulted
#               only to accept a secondmate's shared-pool worktree, see the
#               SECONDMATE case in THE SCOPE TEST below. Absent it, only a
#               worktree of <project> itself is accepted.
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Claude Code gates a folder it has never seen behind an
# interactive workspace-trust dialog, and --dangerously-skip-permissions does
# NOT cover it: `claude --help` records that the dialog is skipped only in
# non-interactive mode (-p, or a non-TTY stdout), and a crewmate pane is
# interactive. Every fresh task worktree therefore hits it. The dialog renders
# with the cursor on "No, exit" and firstmate's steering plane carries only
# Enter, Escape and C-c with no arrow navigation, so firstmate cannot answer it
# and must not try - pressing Enter would select exit. The worker wedges before
# it ever reads the brief. Registering the trust before launch is the only
# control that reaches an interactive pane.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a
# path policy. <worktree> must be a LINKED git worktree - its own git dir,
# sharing <project>'s common dir - whose top level is exactly the resolved
# argument. Git is the ground truth, so the argument is never trusted on its
# own word: a primary checkout (git dir == common dir), a worktree of an
# unrelated repo, a subdirectory of a worktree, a plain directory, and a home
# directory are each refused. Refusal is a non-zero exit, never a warning and
# never a silent skip.
#
# The test is deliberately NOT a treehouse or orca path prefix. Treehouse's
# root is configurable (--root, TREEHOUSE_ROOT, config, and a relative
# in-project pool), so a prefix check would refuse legitimate roots, accept
# whatever a mutable env var names, and add exactly the policy surface this
# registration must not grow. The structural test is verified for treehouse
# worktrees, which are linked git worktrees.
#
# THE SECONDMATE case is the one deliberate widening of the equality above, and
# it stays structural. A secondmate home clones each of its OWN registered
# projects, but its crewmate worktrees come from the shared Treehouse pool, whose
# slots are linked worktrees of the ROOT firstmate home's clone of the same
# project - not of the secondmate's clone. So <worktree>'s git common dir is the
# ROOT clone's while <project> is the secondmate's clone, and the equality can
# never hold there even though the worktree is entirely legitimate. This accepts
# exactly that shape and nothing wider: <home> must be given, <project> must be
# one of that home's OWN registered project clones (home/projects/<name> with
# <name> listed in home/data/projects.md), and <worktree> must be a linked
# worktree of the ROOT home's clone of that SAME project (the root home resolved
# through the owned fm_firstmate_root_home). A worktree of any other repo has a
# different common dir and is still refused; an unregistered project is refused
# before the root clone is ever consulted; and when <home> is absent or any link
# in that chain cannot be established, the ordinary same-project refusal stands.
# This never trusts a directory that is not a firstmate-managed linked worktree.
#
# The test is deliberately NOT a treehouse or orca path prefix. Treehouse's
# docs/orca-backend.md calls it an "independent worktree", which does not
# establish a shared git common dir, and orca is macOS-only and was not installed
# where this was written. If Orca clones instead of linking, its git dir equals
# its common dir, so this refuses it as a primary checkout and an orca claude
# spawn fails loudly here rather than wedging on the dialog later. fm-spawn.sh's
# own validate_spawn_worktree would not catch that case first: it compares the
# worktree root against the primary and never compares common dirs, so an
# independent clone passes it. Close this on a box that has Orca through the live
# opt-in guard family (FM_*_LIVE_E2E=1) and record the result in
# docs/verification/runtime-backends.md, rather than assuming the shape here.
#
# Only the launching user's own store is written: the projects entry for the
# worktree path in ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json, which must be a
# regular file this uid owns. Every unrelated key and project entry is
# preserved, and the replacement is atomic. fm-spawn.sh forwards CLAUDE_CONFIG_DIR
# onto the claude launch verbatim rather than resolving it, and the worker's pane
# starts in the task worktree, so only an absolute value names the same store on
# both sides; a relative one is refused below rather than guessed at.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect any relative `cd` operand - notably the `.git` that
# `git rev-parse --git-common-dir` returns for a primary checkout - into an
# unrelated directory. The git overrides do the same to git's own answers: an
# inherited GIT_DIR with GIT_WORK_TREE makes a primary checkout report a linked
# worktree's git dir, so the primary-checkout refusal would pass. Git exports
# GIT_DIR into every hook environment, so an inherited value is ordinary rather
# than hostile. Clear the whole class once here so every subshell inherits it
# and a later added git call cannot silently reintroduce the hole.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

case "$#" in
  2 | 3) ;;
  *) echo "usage: fm-claude-trust.sh <worktree> <project> [<home>]" >&2; exit 2 ;;
esac
WT_ARG=$1
PROJ_ARG=$2
HOME_ARG=${3:-}

refuse() { echo "error: refusing to pre-register Claude trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The fully resolved path of an existing file, or empty. Resolution runs in node
# because it must follow a symlink chain to its final target, and node is
# already this script's JSON writer.
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

# Whether the registry file lists a project by exactly this name. A membership
# test only: the delivery-posture contract this registry also carries is owned by
# bin/fm-project-mode.sh and is not consulted here.
registry_lists_project() {  # <registry-file> <name>
  local reg=$1 name=$2
  [ -f "$reg" ] || return 1
  awk -v n="$name" '$1=="-" && $2==n { found=1; exit } END { exit(found ? 0 : 1) }' "$reg"
}

# The launching home's ROOT firstmate home, resolved through the one owner of
# that traversal (fm_firstmate_root_home in bin/fm-wake-lib.sh). Sourced in a
# subshell so the library's globals and mkdir never touch this security script's
# own environment, which the unset block above keeps clean; set +u there because
# the library predates this script's set -u.
resolve_root_home() {  # <home>
  local home=$1 root
  # shellcheck source=bin/fm-wake-lib.sh
  root=$( set +u; FM_HOME="$home" . "$SCRIPT_DIR/fm-wake-lib.sh" >/dev/null 2>&1 \
          && fm_firstmate_root_home "$home" 2>/dev/null ) || return 1
  [ -n "$root" ] || return 1
  printf '%s\n' "$root"
}

# The secondmate shared-pool acceptance documented in THE SCOPE TEST. Returns 0
# only when <project> is one of <home>'s OWN registered project clones and
# <worktree> (via its already-resolved common dir) is a linked worktree of the
# ROOT home's clone of that SAME project. Any missing link fails closed.
home_owns_pool_worktree() {  # <home> <project-real> <worktree-common>
  local home=$1 proj_real=$2 wt_common=$3
  local home_real proj_parent name root root_common
  [ -n "$home" ] || return 1
  home_real=$(real_dir "$home") || return 1
  [ -n "$home_real" ] || return 1
  # <project> must be home/projects/<name>, resolved so a symlinked projects dir
  # is still judged against the real launching home.
  proj_parent=$(dirname -- "$proj_real")
  [ "$(basename -- "$proj_parent")" = projects ] || return 1
  [ "$(real_dir "$proj_parent")" = "$(real_dir "$home_real/projects")" ] || return 1
  name=$(basename -- "$proj_real")
  registry_lists_project "$home_real/data/projects.md" "$name" || return 1
  root=$(resolve_root_home "$home_real") || return 1
  [ -d "$root/projects/$name" ] || return 1
  root_common=$(common_dir_of "$root/projects/$name") || return 1
  [ -n "$root_common" ] || return 1
  [ "$root_common" = "$wt_common" ]
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-}}
[ -n "$CONFIG_DIR" ] || refuse "neither CLAUDE_CONFIG_DIR nor HOME is set, so the store cannot be located"
# A relative value resolves against this process's cwd here but against the
# worker's own cwd once fm-spawn.sh forwards it verbatim onto the launch, so the
# two sides can name different stores and the registration would report a
# success the worker never sees. Refuse rather than guess at the worker's cwd.
case ${CLAUDE_CONFIG_DIR:-} in
  '' | /*) ;;
  *) refuse "CLAUDE_CONFIG_DIR '$CLAUDE_CONFIG_DIR' is a relative path, so the store the worker reads cannot be guaranteed to be the one written here; set it to an absolute path" ;;
esac
# fm-spawn forwards a set CLAUDE_CONFIG_DIR onto the launch without requiring it
# to exist, because claude creates its own store directory. Create it here for
# the same reason, and refuse only when it genuinely cannot be written, since a
# store this cannot reach means the worker meets the dialog after all.
CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
if [ -z "$CONFIG_DIR_REAL" ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
fi
[ -n "$CONFIG_DIR_REAL" ] || refuse "Claude config directory '$CONFIG_DIR' does not exist and could not be created"

# A home or config directory is never a task worktree. Checked explicitly so
# the refusal names the real reason instead of the git verdict behind it.
[ "$WT_REAL" != "$CONFIG_DIR_REAL" ] || refuse "'$WT_REAL' is the Claude config directory, not a task worktree"
if [ -n "${HOME:-}" ]; then
  HOME_REAL=$(real_dir "$HOME") || true
  [ "$WT_REAL" != "${HOME_REAL:-}" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"
fi

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
# The worktree must belong to <project> itself, or - only for a launching home's
# own registered project - to the ROOT home's clone of that same project, which
# is where a secondmate's shared-pool slots live. Any other worktree is refused.
if [ "$WT_COMMON" != "$PROJ_COMMON" ] \
  && ! home_owns_pool_worktree "$HOME_ARG" "$PROJ_REAL" "$WT_COMMON"; then
  refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"
fi

# The store write needs node, and a missing interpreter refuses like every other
# failure here. Degrading instead would launch a worker straight into the dialog
# this registration exists to remove, which is the one outcome the whole control
# is for; the other node callers in bin/ step aside because what they protect is
# optional, and this is not. A node-less home never reaches a spawn anyway, since
# bin/fm-bootstrap.sh lists node in COMMON_TOOLS and reports it at setup, which is
# where a missing tool belongs rather than as a stalled pane later.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

STORE="$CONFIG_DIR_REAL/.claude.json"
# A dotfile manager or a synced folder legitimately symlinks this store, so the
# link is followed to its final target and every check below judges that target.
# Ownership is the property that matters: another user's file is refused however
# it is reached. Writing to the resolved path is what keeps the link itself in
# place, since staging beside the link and renaming would replace it with a
# regular file and break that layout.
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write, then read back and confirm. fm-spawn runs from a live
# firstmate Claude Code session that writes this same file, so the store can move
# under us in both directions and each needs its own answer.
#
# Losing the VENDOR's write is the serious one: this renames a whole
# re-serialisation over the file, so anything Claude changed since the read -
# oauthAccount, user-scope mcpServers, another project's history - would be gone,
# in a format this does not own. So the bytes read are fingerprinted and
# re-checked immediately before the rename, and a store that moved is not
# overwritten: the whole read-modify-write is retried once, and a second move
# refuses rather than clobbering.
#
# That narrows the window; it does not close it. Rename cannot be conditioned on
# content, so a write landing between the final check and the rename is still
# lost, and this claims no more than that.
#
# Losing OUR entry is the mild one: a vendor rewrite that drops it only resurrects
# the dialog this registration removes, which reaches firstmate as an ordinary
# stale wake and a relaunch registers again. The readback catches it within these
# attempts, and it must fail loudly rather than report a trust it did not leave.
# ponytail: fingerprint-and-refuse, not a lock; flock is absent on macOS and
# cannot stop a vendor session's own rewrite anyway.
if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, worktree] = process.argv.slice(2);
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.projects === undefined) root.projects = {};
  const projects = root.projects;
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    throw new Error(`${store} has a non-object "projects" value`);
  }
  let entry = projects[worktree];
  if (entry === undefined || entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    entry = {};
  }
  entry.hasTrustDialogAccepted = true;
  projects[worktree] = entry;
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.claude.json.fm-trust.${unique}`);
  // Two-space pretty-printed, because that is the format Claude Code itself
  // writes: the store on the box this was measured on begins "{\n  " and runs
  // 9646 lines. Compact would reformat the operator's whole config on every
  // spawn and the vendor's next write would expand it again, so this must not
  // be "simplified" to JSON.stringify(root) without re-measuring the vendor.
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  return back.projects?.[worktree]?.hasTrustDialogAccepted === true ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${worktree} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
