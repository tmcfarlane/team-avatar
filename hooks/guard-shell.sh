#!/usr/bin/env bash
# beforeShellExecution hook — guards the agent's shell calls.
#
# Reads a JSON payload on stdin (fields: command, cwd, hook_event_name, ...) and prints a
# JSON decision on stdout per Cursor's hook protocol:
#   {"permission": "allow|deny|ask", "user_message": "...", "agent_message": "..."}
# Cursor 3.27 blocks the command when a permission hook prints invalid JSON or keys outside that
# schema, so every message goes through json_str and only the documented keys are printed.
#
# Blocks (deny) clearly destructive commands and commits that contain the anti-patterns
# Team Avatar agents are told never to introduce.
#
# Robustness notes (learned from validation on Cursor 3.8.23):
#  - Cursor runs hooks with the GUI app's PATH, which often LACKS /opt/homebrew/bin, so we
#    cannot assume `python3` or `jq` are on PATH. We try jq, then python3 at known absolute
#    paths, then /usr/bin/perl (always present on macOS). If the payload can't be parsed we
#    return "ask" (surface) rather than silently allowing.
#  - We cd into the payload's `cwd` before running git checks so `git diff --cached` resolves
#    in the agent's actual worktree.
#  - Pair with "failClosed": true in hooks.json so a script error denies instead of allowing.
#
# Env switches:
#   OMC_HOOKS_OBSERVE=1  run non-blocking: downgrade every deny to allow + an informational note.
#   OMC_HOOKS_DEBUG=1    append each invocation's command to hooks/last-invocation.log (proves firing).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="$(cat)"

# --- Robust JSON string-field extraction (no reliance on PATH) ---
json_field() {
  local field="$1" data="$2" out py
  if command -v jq >/dev/null 2>&1; then
    if out="$(printf '%s' "$data" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null)"; then
      printf '%s' "$out"; return 0
    fi
  fi
  for py in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if "$py" -c '' >/dev/null 2>&1; then
      if out="$(printf '%s' "$data" | "$py" -c "import sys,json;print(json.load(sys.stdin).get('$field',''))" 2>/dev/null)"; then
        printf '%s' "$out"; return 0
      fi
    fi
  done
  if [ -x /usr/bin/perl ]; then
    printf '%s' "$data" | /usr/bin/perl -0777 -ne 'if(/"'"$field"'"\s*:\s*"((?:[^"\\]|\\.)*)"/s){my $x=$1;$x=~s/\\n/\n/g;$x=~s/\\t/\t/g;$x=~s/\\(.)/$1/g;print $x}' 2>/dev/null
    return 0
  fi
  return 1
}

COMMAND="$(json_field command "$INPUT")"; PARSE_RC=$?
CWD="$(json_field cwd "$INPUT")"

if [ "${OMC_HOOKS_DEBUG:-}" = "1" ]; then
  printf '%s\t%s\n' "$(date '+%FT%T' 2>/dev/null)" "${COMMAND:-<unparsed>}" >> "$HERE/last-invocation.log" 2>/dev/null || true
fi

# Escapes a value for a JSON string: backslashes and quotes, with control characters as spaces.
json_str() { printf '%s' "$1" | LC_ALL=C tr '\000-\037' ' ' | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
allow() { printf '{"permission": "allow"}\n'; exit 0; }
ask() { local m; m="$(json_str "$1")"; printf '{"permission": "ask", "user_message": "%s", "agent_message": "%s"}\n' "$m" "$m"; exit 0; }
decide() {
  local reason; reason="$(json_str "$1")"
  if [ "${OMC_HOOKS_OBSERVE:-}" = "1" ]; then
    printf '{"permission": "allow", "agent_message": "[observe] would block: %s"}\n' "$reason"
    exit 0
  fi
  printf '{"permission": "deny", "user_message": "Blocked by oh-my-cursor: %s", "agent_message": "Denied by policy: %s. Adjust hooks/guard-shell.sh or set OMC_HOOKS_OBSERVE=1 to override."}\n' "$reason" "$reason"
  exit 0
}
# Surface for human approval (deterministic "hold for review"). Used where the auto-review
# classifier is unreliable, e.g. reading credential/secret files.
hold() {
  local reason; reason="$(json_str "$1")"
  if [ "${OMC_HOOKS_OBSERVE:-}" = "1" ]; then
    printf '{"permission": "allow", "agent_message": "[observe] would hold for review: %s"}\n' "$reason"
    exit 0
  fi
  printf '{"permission": "ask", "user_message": "Held by oh-my-cursor for review: %s", "agent_message": "Held for review: %s. Approve only if this credential/secret access is intended."}\n' "$reason" "$reason"
  exit 0
}

# Received a payload but couldn't parse the command -> surface instead of silently allowing.
if [ -n "$INPUT" ] && { [ "$PARSE_RC" -ne 0 ] || { [ -z "$COMMAND" ] && printf '%s' "$INPUT" | grep -q '"command"'; }; }; then
  [ "${OMC_HOOKS_OBSERVE:-}" = "1" ] && allow
  ask "oh-my-cursor guard could not parse the shell command; review before running"
fi

[ -z "$COMMAND" ] && allow

# Resolve git checks in the agent's real worktree. A plugin hook starts in the plugin's folder, and
# Cursor 3.27 sends an empty cwd when the shell call names no directory, so fall back to the
# workspace root.
for dir in "$CWD" "${CURSOR_PROJECT_DIR:-}"; do
  if [ -n "$dir" ] && [ -d "$dir" ] && cd "$dir" 2>/dev/null; then break; fi
done

# --- Destructive command denylist (unambiguous, always guarded) ---
case "$COMMAND" in
  *"rm -rf /"*|*"rm -rf ~"*|*"rm -rf /*"*|*":(){ :|:& };:"*) decide "destructive filesystem command" ;;
  *"git push"*"--force"*"main"*|*"git push"*"--force"*"master"*|*"git push -f"*"main"*|*"git push -f"*"master"*) decide "force-push to a protected branch" ;;
  *"git reset --hard origin/main"*|*"git reset --hard origin/master"*) decide "hard reset of a shared branch" ;;
  *"chmod -R 777 /"*|*"mkfs"*|*"dd if="*"of=/dev/"*) decide "system-level destructive command" ;;
esac

# --- Commit anti-pattern guard ---
# The check reads what is staged before the command runs, so a command that also stages files
# would commit changes the check never saw.
case "$COMMAND" in
  *"git commit"*)
    if [[ "$COMMAND" == *"git add"* || "$COMMAND" == *"git stage"* ]] ||
      [[ "$COMMAND" =~ git[[:space:]]+commit.*[[:space:]](-[A-Za-z]*a[A-Za-z]*|--all)([[:space:]]|$) ]]; then
      decide "commit in the same command that stages files; run git add first, then git commit in a separate command"
    fi
    if [ -x "$HERE/pre-commit-check.sh" ]; then
      if ! OUT="$("$HERE/pre-commit-check.sh" 2>&1)"; then
        decide "commit contains forbidden anti-patterns ($(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-160))"
      fi
    fi
    ;;
esac

# --- Credential / secret access guard (hold for review) ---
# The permissions.json auto-review classifier is best-effort and let `cat ~/.ssh/config`
# through during E2E test C2, so enforce a deterministic hold here regardless of the classifier.
case "$COMMAND" in
  *"/.ssh/"*|*"/.aws/"*|*"/.gnupg/"*|*"id_rsa"*|*"id_dsa"*|*"id_ecdsa"*|*"id_ed25519"*|*".pem"*|*".netrc"*|*".pgpass"*|*"/.kube/config"*|*"kubeconfig"*|*"/.docker/config.json"*|*"/.config/gcloud/"*|*".aws/credentials"*)
    hold "command accesses a credential/secret file" ;;
esac

allow
