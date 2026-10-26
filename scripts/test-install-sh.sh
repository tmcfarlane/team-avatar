#!/usr/bin/env bash
# Runs install.sh against throwaway HOME directories and checks the result with explicit assertions.
# Never touches the real HOME. Needs git, python3, curl, and the v0.4.2 tag, the last release
# that installed straight into ~/.cursor/.
# usage: bash scripts/test-install-sh.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
REAL_HOME="$HOME"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
export NO_COLOR=1

pass=0
fails=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
check() { # description command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
check_not() { # description command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}
eq() { # description actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '      got:      %s\n      expected: %s\n' "$2" "$3"; fi
}

new_dir() { mktemp -d "$TMP/$1.XXXXXX"; }
new_home() {
  local h
  h="$(new_dir home)"
  [ "$h" != "$REAL_HOME" ] || { echo "refusing to use the real HOME"; exit 2; }
  printf '%s' "$h"
}

# run_installer <home> <cwd> <installer> args...  (output in $OUT, status in $STATUS)
run_installer() {
  local h="$1" cwd="$2" script="$3"; shift 3
  OUT="$(cd "$cwd" && HOME="$h" bash "$script" "$@" 2>&1)"
  STATUS=$?
}
install_user() { run_installer "$1" "$TMP" "$INSTALLER" "${@:2}"; }

snapshot() { # dir
  (cd "$1" && find . -print | sort && find . -type f -exec cksum {} + | sort)
}
files() { (cd "$1" && find . -type f | sort); }
valid_json() { python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$1"; }

AGENTS="aang sokka katara zuko toph appa momo iroh"
COMMANDS="plan build search fix tasks scout cactus-juice doc image"
HOOKS="post-edit-lint.sh pre-commit-check.sh guard-shell.sh"
# Every folder under skills/ must ship, so a folder missing from the installer's SKILL_DIRS fails.
REPO_SKILLS="$(cd "$ROOT/skills" && find . -mindepth 1 -maxdepth 1 -type d | sort)"

expected_plugin_files() { # everything except skills/, sorted
  {
    echo ./.cursor-plugin/plugin.json
    for a in $AGENTS; do echo "./agents/$a.md"; done
    echo ./agents/protocols/team-avatar.md
    echo ./rules/orchestrator.mdc
    for c in $COMMANDS; do echo "./commands/$c.md"; done
    echo ./hooks/hooks.json
    for h in $HOOKS; do echo "./hooks/$h"; done
  } | sort
}

assert_plugin_layout() { # label plugin-dir
  local label="$1" p="$2"
  eq "$label: plugin files match the spec layout" \
    "$(cd "$p" && find . -type f -not -path './skills/*' | sort)" "$(expected_plugin_files)"
  eq "$label: every bundled skill folder" \
    "$(cd "$p/skills" && find . -mindepth 1 -maxdepth 1 -type d | sort)" "$REPO_SKILLS"
  check "$label: planning skill has SKILL.md" test -f "$p/skills/planning/SKILL.md"
  for h in $HOOKS; do check "$label: hooks/$h is executable" test -x "$p/hooks/$h"; done
  check "$label: plugin.json is valid JSON" valid_json "$p/.cursor-plugin/plugin.json"
  check "$label: hooks/hooks.json is valid JSON" valid_json "$p/hooks/hooks.json"
  check "$label: plugin.json matches the repo" cmp -s "$ROOT/.cursor-plugin/plugin.json" "$p/.cursor-plugin/plugin.json"
  check "$label: hooks/hooks.json matches the repo" cmp -s "$ROOT/hooks/hooks.json" "$p/hooks/hooks.json"
  check_not "$label: no root hooks.json in the plugin" test -e "$p/hooks.json"
  check_not "$label: no permissions.json in the plugin" test -e "$p/permissions.json"
}

printf '== syntax\n'
check "bash -n install.sh" bash -n "$INSTALLER"
eq "version is 0.5.0" "$(bash "$INSTALLER" --version)" "0.5.0"
check "usage names the Enterprise setting" bash -c "bash '$INSTALLER' --help | grep -q 'Allow Local Plugin Imports'"

printf '== 1. fresh user-scope install\n'
H1="$(new_home)"
install_user "$H1"
eq "install exits 0" "$STATUS" "0"
P1="$H1/.cursor/plugins/local/team-avatar"
assert_plugin_layout "fresh" "$P1"
check "fresh: permissions.json created at ~/.cursor" cmp -s "$ROOT/permissions.json" "$H1/.cursor/permissions.json"
eq "fresh: ~/.cursor holds only plugins/ and permissions.json" \
  "$(cd "$H1/.cursor" && ls | tr '\n' ' ')" "permissions.json plugins "
check "fresh: output says restart Cursor" bash -c "printf '%s' \"\$1\" | grep -q 'Developer: Reload Window'" _ "$OUT"
check "fresh: output names the label" bash -c "printf '%s' \"\$1\" | grep -q 'Cursor 3.27+'" _ "$OUT"

printf '== 1b. existing different permissions.json is left alone\n'
H1B="$(new_home)"
mkdir -p "$H1B/.cursor"
printf '{"mine": true}\n' > "$H1B/.cursor/permissions.json"
install_user "$H1B"
eq "permissions.json untouched" "$(cat "$H1B/.cursor/permissions.json")" '{"mine": true}'
check "one line says it was left" bash -c "printf '%s' \"\$1\" | grep -q 'permissions.json unchanged'" _ "$OUT"
install_user "$H1B" --force
eq "permissions.json untouched under --force" "$(cat "$H1B/.cursor/permissions.json")" '{"mine": true}'

printf '== 1c. --no-skills\n'
H1C="$(new_home)"
install_user "$H1C" --no-skills
check_not "no skills folder installed" test -d "$H1C/.cursor/plugins/local/team-avatar/skills"

printf '== 1d. a skill with a bundled name in ~/.agents/skills\n'
H1D="$(new_home)"
mkdir -p "$H1D/.agents/skills/planning"
printf -- '---\nname: planning\ndescription: my planning notes\n---\n' > "$H1D/.agents/skills/planning/SKILL.md"
install_user "$H1D"
eq "with ~/.agents/skills: installer exits 0" "$STATUS" "0"
check "the note names the duplicate skill" bash -c "printf '%s' \"\$1\" | grep -q 'bundled names: planning'" _ "$OUT"
check_not "the installer never suggests deleting a folder" bash -c "printf '%s' \"\$1\" | grep -qi 'delete'" _ "$OUT"
check "~/.agents/skills is untouched" test -f "$H1D/.agents/skills/planning/SKILL.md"

printf '== 1e. the Claude Code edition is installed too\n'
check_not "a plain install says nothing about the Claude Code edition" bash -c "printf '%s' \"\$1\" | grep -q 'Claude Code edition'" _ "$(cd "$TMP" && HOME="$(new_home)" bash "$INSTALLER" 2>&1)"
H1E="$(new_home)"
mkdir -p "$H1E/.claude/plugins"
printf '{"version": 2, "plugins": {"team-avatar@team-avatar": [{"scope": "user"}]}}\n' > "$H1E/.claude/plugins/installed_plugins.json"
install_user "$H1E"
eq "with the Claude Code edition: installer exits 0" "$STATUS" "0"
check "the installer warns about the Claude Code edition" bash -c "printf '%s' \"\$1\" | grep -q 'Claude Code edition of Team Avatar is installed'" _ "$OUT"
check "the warning names the Cursor setting" bash -c "printf '%s' \"\$1\" | grep -q 'Include Third-Party Plugins'" _ "$OUT"

printf '== 2. migration from the old layout\n'
OLD="$(new_dir old)"
git -C "$ROOT" archive v0.4.2 | tar -x -C "$OLD"
H2="$(new_home)"
run_installer "$H2" "$TMP" "$OLD/install.sh"
eq "old installer exits 0" "$STATUS" "0"
check "old layout: agents/toph.md installed" test -f "$H2/.cursor/agents/toph.md"
check "old layout: toph has a sentence name" bash -c "sed -n 2p '$H2/.cursor/agents/toph.md' | grep -q '^name: toph is '"
check "old layout: rules/orchestrator.mdc installed" test -f "$H2/.cursor/rules/orchestrator.mdc"
check "old layout: hooks/guard-shell.sh installed" test -f "$H2/.cursor/hooks/guard-shell.sh"
check "old layout: skills/planning installed" test -d "$H2/.cursor/skills/planning"
cp "$H2/.cursor/agents/toph.md" "$TMP/old-toph.md"
printf 'my own command\n' > "$H2/.cursor/commands/search.md"
printf -- '---\nname: myagent\n---\n' > "$H2/.cursor/agents/myagent.md"
printf 'user rule\n' > "$H2/.cursor/rules/mine.mdc"
mkdir -p "$H2/.cursor/skills/my-skill" && printf 'x\n' > "$H2/.cursor/skills/my-skill/SKILL.md"
printf -- '---\nname: momo-helper\n---\n' > "$H2/.cursor/agents/momo.md"
rm -rf "$H2/.cursor/skills/refactoring" && mkdir -p "$H2/.cursor/skills/refactoring"
printf -- '---\nname: refactoring\ndescription: my own refactoring notes\n---\n' > "$H2/.cursor/skills/refactoring/SKILL.md"
(cd "$H2/.cursor" && find . -type f | sort) > "$TMP/old-files.txt"

install_user "$H2"
eq "new installer exits 0 over the old layout" "$STATUS" "0"
assert_plugin_layout "migrated" "$H2/.cursor/plugins/local/team-avatar"
B2="$(ls -d "$H2"/.cursor/team-avatar-backup-* 2>/dev/null | head -n 1)"
eq "exactly one backup folder" "$(ls -d "$H2"/.cursor/team-avatar-backup-* | wc -l | tr -d ' ')" "1"
check "backup holds the old toph byte for byte" cmp -s "$TMP/old-toph.md" "$B2/agents/toph.md"
check "backup holds the old rule" test -f "$B2/rules/orchestrator.mdc"
check "backup holds the old protocol" test -f "$B2/agents/protocols/team-avatar.md"
check "backup holds an old command" test -f "$B2/commands/plan.md"
check "backup holds an old hook" test -f "$B2/hooks/guard-shell.sh"
check "backup holds an old skill folder" test -f "$B2/skills/planning/SKILL.md"
check_not "old agent removed from ~/.cursor/agents" test -e "$H2/.cursor/agents/toph.md"
check_not "old rule removed from ~/.cursor/rules" test -e "$H2/.cursor/rules/orchestrator.mdc"
check_not "old skill removed from ~/.cursor/skills" test -e "$H2/.cursor/skills/planning"
check "backup holds cactus-juice.md, which names no character" test -f "$B2/commands/cactus-juice.md"
check "a user's own momo.md (name: momo-helper) stays" grep -q '^name: momo-helper$' "$H2/.cursor/agents/momo.md"
check "a user's own skill with a bundled name stays" grep -q 'my own refactoring notes' "$H2/.cursor/skills/refactoring/SKILL.md"
eq "files left outside plugin and backup are the user's own plus permissions.json" \
  "$(cd "$H2/.cursor" && find . -type f -not -path './plugins/*' -not -path './team-avatar-backup-*/*' | sort)" \
  "$(printf '%s\n' ./agents/momo.md ./agents/myagent.md ./commands/search.md ./permissions.json ./rules/mine.mdc ./skills/my-skill/SKILL.md ./skills/refactoring/SKILL.md | sort)"
OLD_COUNT="$(grep -c . "$TMP/old-files.txt")"
BACKUP_COUNT="$(cd "$B2" && find . -type f | wc -l | tr -d ' ')"
eq "backup holds every old file except the 6 left in place" "$BACKUP_COUNT" "$((OLD_COUNT - 6))"
check "output prints each moved path" bash -c "printf '%s' \"\$1\" | grep -q '\[moved\].*agents/toph.md'" _ "$OUT"
snap_a="$(snapshot "$H2")"
install_user "$H2"
eq "second run after migration changes nothing" "$(snapshot "$H2")" "$snap_a"

printf '== 2b. backup rules on hand-made files\n'
H2B="$(new_home)"
C2B="$H2B/.cursor"
mkdir -p "$C2B/agents" "$C2B/commands" "$C2B/hooks"
printf -- '---\nname: aang - Executes & Debugs Code\n---\n' > "$C2B/agents/aang.md"
printf 'Fix it. Apparently this works.\n' > "$C2B/commands/fix.md"
printf '#!/bin/sh\n# my own guard hook\n' > "$C2B/hooks/guard-shell.sh"
git -C "$ROOT" show v0.4.2:hooks/post-edit-lint.sh > "$C2B/hooks/post-edit-lint.sh"
mkdir -p "$C2B/skills/vercel-composition-patterns"
printf -- '---\nname: vercel-composition-patterns\ndescription:\n  My own notes on composition.\n---\n' > "$C2B/skills/vercel-composition-patterns/SKILL.md"
install_user "$H2B"
eq "hand-made files: installer exits 0" "$STATUS" "0"
B2B="$(ls -d "$C2B"/team-avatar-backup-* 2>/dev/null | head -n 1)"
check "an agent named 'aang - ...' moves" test -f "$B2B/agents/aang.md"
check "a command that only says 'apparently' stays" test -f "$C2B/commands/fix.md"
check "a hook script with its own second line stays" test -f "$C2B/hooks/guard-shell.sh"
check "a shipped hook script moves" test -f "$B2B/hooks/post-edit-lint.sh"
check "a same-named skill with its own multi-line description stays" test -f "$C2B/skills/vercel-composition-patterns/SKILL.md"
H2C="$(new_home)"
run_installer "$H2C" "$TMP" "$OLD/install.sh"
printf '{"version": 1, "hooks": {}}\n' > "$H2C/.cursor/hooks.json"
install_user "$H2C"
check "with a user hooks.json, old hook scripts stay" test -f "$H2C/.cursor/hooks/guard-shell.sh"
H2D="$(new_home)"
run_installer "$H2D" "$TMP" "$OLD/install.sh"
install_user "$H2D" --no-skills
eq "--no-skills over the old layout exits 0" "$STATUS" "0"
check "--no-skills leaves the old skill folders" test -f "$H2D/.cursor/skills/planning/SKILL.md"

printf '== 3. --uninstall\n'
H3="$(new_home)"
install_user "$H3"
install_user "$H3" --uninstall
eq "uninstall exits 0" "$STATUS" "0"
check_not "plugin folder removed" test -e "$H3/.cursor/plugins/local/team-avatar"
H3B="$(new_home)"
run_installer "$H3B" "$TMP" "$OLD/install.sh"
install_user "$H3B" --uninstall
eq "uninstall over old layout exits 0" "$STATUS" "0"
check_not "uninstall over old layout: no plugin" test -e "$H3B/.cursor/plugins/local/team-avatar"
B3="$(ls -d "$H3B"/.cursor/team-avatar-backup-* 2>/dev/null | head -n 1)"
check "uninstall backed up the old agent" test -f "$B3/agents/toph.md"
check_not "uninstall left no old agent behind" test -e "$H3B/.cursor/agents/toph.md"
check_not "uninstall left no old skill behind" test -e "$H3B/.cursor/skills/planning"
install_user "$H3B" --uninstall
eq "uninstall twice exits 0" "$STATUS" "0"
H3C="$(new_home)"
install_user "$H3C"
mkdir -p "$H3C/.cursor/skills" && cp -R "$ROOT/skills/planning" "$H3C/.cursor/skills/planning"
LONE3="$(new_dir lone)"
cp "$INSTALLER" "$LONE3/install.sh"
OUT="$(cd "$TMP" && HOME="$H3C" OH_MY_CURSOR_SOURCE_BASE_URL="http://127.0.0.1:9" bash "$LONE3/install.sh" --uninstall 2>&1)"
STATUS=$?
eq "offline uninstall from a lone copy exits 0" "$STATUS" "0"
check_not "offline uninstall removed the plugin" test -e "$H3C/.cursor/plugins/local/team-avatar"
check "offline uninstall left the old skill in place" test -f "$H3C/.cursor/skills/planning/SKILL.md"
check "offline uninstall says why" bash -c "printf '%s' \"\$1\" | grep -q 'Could not read the bundled skills'" _ "$OUT"

printf '== 4. --disable then --enable\n'
H4="$(new_home)"
install_user "$H4"
P4="$H4/.cursor/plugins/local/team-avatar"
install_user "$H4" --disable
check_not "disable: rule file gone" test -e "$P4/rules/orchestrator.mdc"
check "disable: disabled rule present" test -f "$P4/rules/orchestrator.mdc.disabled"
install_user "$H4" --enable
check "enable: rule file back" test -f "$P4/rules/orchestrator.mdc"
check_not "enable: disabled rule gone" test -e "$P4/rules/orchestrator.mdc.disabled"
check "enable: rule matches the repo" cmp -s "$ROOT/rules/orchestrator.mdc" "$P4/rules/orchestrator.mdc"
eq "toggle left nothing in ~/.cursor/rules" "$(ls "$H4/.cursor/rules" 2>/dev/null | wc -l | tr -d ' ')" "0"

printf '== 5. --project keeps the ./.cursor layout\n'
H5="$(new_home)"
REPO5="$(new_dir repo)"
git -C "$REPO5" init -q
run_installer "$H5" "$REPO5" "$INSTALLER" --project
eq "project install exits 0" "$STATUS" "0"
C5="$REPO5/.cursor"
for a in $AGENTS; do check "project: agents/$a.md" test -f "$C5/agents/$a.md"; done
check "project: agents/protocols/team-avatar.md" test -f "$C5/agents/protocols/team-avatar.md"
check "project: rules/orchestrator.mdc" test -f "$C5/rules/orchestrator.mdc"
for c in $COMMANDS; do check "project: commands/$c.md" test -f "$C5/commands/$c.md"; done
for h in $HOOKS; do check "project: hooks/$h" test -f "$C5/hooks/$h"; done
check "project: hooks.json matches the repo root hooks.json" cmp -s "$ROOT/hooks.json" "$C5/hooks.json"
check "project: hooks.json uses .cursor/hooks/ paths" grep -q '"\.cursor/hooks/guard-shell\.sh"' "$C5/hooks.json"
check_not "project: hooks.json has no ./hooks/ paths" grep -q '"\./hooks/' "$C5/hooks.json"
check_not "project: no hooks/hooks.json" test -e "$C5/hooks/hooks.json"
check "project: permissions.json" test -f "$C5/permissions.json"
check "project: skills/planning" test -f "$C5/skills/planning/SKILL.md"
check_not "project: no .cursor-plugin" test -e "$C5/.cursor-plugin"
check_not "project: no plugins folder" test -e "$C5/plugins"
eq "project install left the throwaway HOME empty" "$(ls -A "$H5" | wc -l | tr -d ' ')" "0"
snap_p="$(snapshot "$REPO5")"
run_installer "$H5" "$REPO5" "$INSTALLER" --project
eq "project install twice gives the same tree" "$(snapshot "$REPO5")" "$snap_p"
run_installer "$H5" "$REPO5" "$INSTALLER" --project --uninstall
eq "project uninstall exits 0" "$STATUS" "0"
check_not "project uninstall removed agents/toph.md" test -e "$C5/agents/toph.md"
check_not "project uninstall removed hooks.json" test -e "$C5/hooks.json"

printf '== 6. --dry-run changes nothing\n'
H6="$(new_home)"
before="$(snapshot "$H6")"
install_user "$H6" --dry-run
eq "dry run on a fresh HOME exits 0" "$STATUS" "0"
eq "dry run on a fresh HOME changes nothing" "$(snapshot "$H6")" "$before"
H6B="$(new_home)"
run_installer "$H6B" "$TMP" "$OLD/install.sh"
before="$(snapshot "$H6B")"
install_user "$H6B" --dry-run
eq "dry run over the old layout exits 0" "$STATUS" "0"
eq "dry run over the old layout changes nothing" "$(snapshot "$H6B")" "$before"
check "dry run prints what would move" bash -c "printf '%s' \"\$1\" | grep -q '\[would move\].*agents/toph.md'" _ "$OUT"
install_user "$H6B" --uninstall --dry-run
eq "dry-run uninstall changes nothing" "$(snapshot "$H6B")" "$before"
H6C="$(new_home)"
install_user "$H6C"
before="$(snapshot "$H6C")"
install_user "$H6C" --uninstall --dry-run
eq "dry-run uninstall of a plugin changes nothing" "$(snapshot "$H6C")" "$before"
install_user "$H6C" --disable --dry-run
eq "dry-run disable changes nothing" "$(snapshot "$H6C")" "$before"
REPO6="$(new_dir repo)"
git -C "$REPO6" init -q
before="$(snapshot "$REPO6")"
run_installer "$H6" "$REPO6" "$INSTALLER" --project --dry-run
eq "dry run in project scope changes nothing" "$(snapshot "$REPO6")" "$before"

printf '== 7. running twice gives the same tree\n'
H7="$(new_home)"
install_user "$H7"
first="$(snapshot "$H7")"
install_user "$H7"
eq "second run exits 0" "$STATUS" "0"
eq "second run gives the same tree" "$(snapshot "$H7")" "$first"
check "second run reports nothing new" bash -c "! printf '%s' \"\$1\" | grep -qE '\[(installed|updated|moved)\]'" _ "$OUT"
install_user "$H7" --force
eq "--force run gives the same tree" "$(snapshot "$H7")" "$first"
printf 'tampered\n' > "$H7/.cursor/plugins/local/team-avatar/agents/toph.md"
install_user "$H7"
eq "without --force a changed plugin file is kept" "$(cat "$H7/.cursor/plugins/local/team-avatar/agents/toph.md")" "tampered"
install_user "$H7" --force
check "--force restores the plugin file" cmp -s "$ROOT/agents/toph.md" "$H7/.cursor/plugins/local/team-avatar/agents/toph.md"
eq "tree is the same again after --force" "$(snapshot "$H7")" "$first"

printf '== remote mode against a local http server\n'
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 &
SERVER_PID=$!
up=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl -fsS "http://127.0.0.1:$PORT/install.sh" -o /dev/null 2>/dev/null; then up=true; break; fi
  sleep 0.25
done
if [ "$up" = true ]; then
  BIN8="$(new_dir bare)"
  cp "$INSTALLER" "$BIN8/install.sh"
  H8="$(new_home)"
  OUT="$(cd "$TMP" && HOME="$H8" OH_MY_CURSOR_SOURCE_BASE_URL="http://127.0.0.1:$PORT" bash "$BIN8/install.sh" 2>&1)"
  STATUS=$?
  eq "remote install exits 0" "$STATUS" "0"
  assert_plugin_layout "remote" "$H8/.cursor/plugins/local/team-avatar"
  eq "remote install builds the same plugin tree as the local install" \
    "$(snapshot "$H8/.cursor/plugins/local/team-avatar")" "$(snapshot "$P1")"
else
  bad "remote: http server did not start"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fails"
[ "$fails" -eq 0 ]
