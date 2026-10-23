#!/usr/bin/env bash
# bin/backends/sandcastle.sh - the sandcastle session-provider adapter.
#
# Unlike tmux/herdr/zellij/orca/cmux, sandcastle does not run the agent inside
# a terminal pane. Instead it invokes `sandcastle.run()` as a Node.js process
# which creates a Docker container (via the firstmateDocker provider), bind
# mounts the pre-acquired Treehouse worktree, and runs the pi/opencode crewmate
# agent inside it. Firstmate captain, Herdr server, and Treehouse stay on the
# host; only the crewmate agent runs in the container.
#
# The worktree is acquired directly on the host via `treehouse get` (not sent
# to a pane), and `launch-brief.md` is written into it before sandcastle.run()
# is invoked. The sandcastle Node.js process is long-lived for the duration of
# the task; its PID is recorded so the watcher and teardown can signal it.
#
# Sourced only through bin/fm-backend.sh's fm_backend_source.
#
# Required tools: docker, treehouse, node (sandcastle CLI).

FM_BACKEND_SANDCASTLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_SANDCASTLE_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Per-task sandcastle process PID file. The watcher reads this to supervise
# the crewmate container; teardown kills it.
fm_backend_sandcastle_pid_file() {  # <state-dir> <task-id>
  printf '%s/%s.sandcastle.pid' "$1" "$2"
}

# Per-task sandcastle log file. stdout/stderr of the sandcastle.run() process.
fm_backend_sandcastle_log_file() {  # <state-dir> <task-id>
  printf '%s/%s.sandcastle.log' "$1" "$2"
}

# fm_backend_sandcastle_capture: bounded plain-text capture of the sandcastle
# process log. Reads the last N lines of the log file.
fm_backend_sandcastle_capture() {  # <target-unused> <lines>
  local lines=$2
  local log_file
  log_file=$(fm_backend_sandcastle_log_file "$FM_HOME/state" "${3:-}") || return 1
  [ -f "$log_file" ] || { printf ''; return 0; }
  tail -n "$lines" "$log_file" 2>/dev/null || true
}

# fm_backend_sandcastle_visible_capture: sandcastle has no terminal viewport.
# Declared unsupported; callers must fail closed.
fm_backend_sandcastle_visible_capture() {  # <target-unused>
  echo "error: sandcastle backend has no visible-capture primitive" >&2
  return 1
}

# fm_backend_sandcastle_send_key: sandcastle has no terminal to send keys to.
fm_backend_sandcastle_send_key() {  # <target-unused> <key>
  echo "error: sandcastle backend has no send-key primitive" >&2
  return 1
}

# fm_backend_sandcastle_send_text_submit: sandcastle receives the brief through
# sandcastle.run() arguments, not via terminal text submission.
fm_backend_sandcastle_send_text_submit() {  # <target-unused> <text> ...
  echo "error: sandcastle backend has no send-text-submit primitive" >&2
  return 1
}

# fm_backend_sandcastle_kill: stop the sandcastle Node.js process for a task.
# Returns 0 if the process was stopped or was already gone.
fm_backend_sandcastle_kill() {  # <target-unused>
  local pid_file log_file pid
  pid_file=$(fm_backend_sandcastle_pid_file "$FM_HOME/state" "${2:-}") || return 1
  [ -f "$pid_file" ] || return 0
  pid=$(cat "$pid_file" 2>/dev/null || true)
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    # Wait briefly for graceful exit
    local i=0
    while [ "$i" -lt 30 ]; do
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pid_file" 2>/dev/null || true
        return 0
      fi
      sleep 0.2
      i=$((i + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file" 2>/dev/null || true
  return 0
}

# fm_backend_sandcastle_agent_state: report whether the sandcastle process is
# alive (running) or dead. Prints "running" or "dead".
fm_backend_sandcastle_agent_state() {  # <target-unused>
  local pid_file pid
  pid_file=$(fm_backend_sandcastle_pid_file "$FM_HOME/state" "${2:-}") || return 1
  [ -f "$pid_file" ] || { printf 'dead'; return 0; }
  pid=$(cat "$pid_file" 2>/dev/null || true)
  [ -n "$pid" ] || { printf 'dead'; return 0; }
  if kill -0 "$pid" 2>/dev/null; then
    printf 'running'
  else
    printf 'dead'
    rm -f "$pid_file" 2>/dev/null || true
  fi
}

# fm_backend_sandcastle_container_ensure: not applicable - Docker containers
# are created and destroyed by sandcastle.run() itself. Prints empty.
fm_backend_sandcastle_container_ensure() {  # <home-unused> <relationship-unused>
  printf ''
}

# fm_backend_sandcastle_create_task: acquire a worktree via treehouse get,
# write launch-brief.md, and invoke sandcastle.run(). Echoes the worktree path.
# This is the sandcastle equivalent of fm_backend_*_create_task.
fm_backend_sandcastle_create_task() {  # <session-unused> <window-name> <project-abs> <default-tab-unused>
  local _ses=$1 _win=$2 proj_abs=$3 _tab=$4
  local wt brief_path pid log_file sandcastle_cmd node_args

  # Acquire the worktree directly on the host via treehouse get.
  wt=$(treehouse get "$proj_abs" 2>&1) || {
    echo "error: treehouse get failed for $proj_abs" >&2
    return 1
  }
  [ -d "$wt" ] || {
    echo "error: treehouse get returned non-directory: $wt" >&2
    return 1
  }

  # Write launch-brief.md into the worktree.
  brief_path="$wt/launch-brief.md"
  if [ -n "${BRIEF_REAL:-}" ] && [ -f "$BRIEF_REAL" ]; then
    cp "$BRIEF_REAL" "$brief_path"
  elif [ -n "${BRIEF:-}" ]; then
    printf '%s\n' "$BRIEF" > "$brief_path"
  else
    echo "error: no launch brief available for sandcastle task" >&2
    return 1
  fi

  # Build the sandcastle.run() invocation. We launch a small Node.js script
  # that imports sandcastle and calls run() with the firstmateDocker provider
  # and pi agent.
  local sandcastle_script
  sandcastle_script=$(cat <<NODEEOF
import { run } from "@ai-hero/sandcastle";
import { firstmateDocker } from "@ai-hero/sandcastle/sandboxes/firstmate-docker";
import { pi } from "@ai-hero/sandcastle/agents/pi";

const brief = \`$(cat "$brief_path" | sed 's/`/\\\\`/g')\`;

await run({
  agent: pi(process.env.FM_MODEL || "claude-opus-4-8", {
    thinking: process.env.FM_THINKING || "high",
    env: {
      FM_TASK_ID: process.env.FM_TASK_ID,
      FM_MODE: process.env.FM_MODE,
      FM_YOLO: process.env.FM_YOLO,
      FM_BRANCH_PREFIX: process.env.FM_BRANCH_PREFIX,
      FM_BASE_BRANCH: process.env.FM_BASE_BRANCH,
      FM_FORGE: process.env.FM_FORGE,
      FM_HARNESS: process.env.FM_HARNESS,
    },
  }),
  sandbox: firstmateDocker({
    imageName: process.env.FM_SANDCASTLE_IMAGE || "firstmate-crewmate",
    env: {
      FM_TASK_ID: process.env.FM_TASK_ID,
      FM_MODE: process.env.FM_MODE,
      FM_YOLO: process.env.FM_YOLO,
      FM_BRANCH_PREFIX: process.env.FM_BRANCH_PREFIX,
      FM_BASE_BRANCH: process.env.FM_BASE_BRANCH,
      FM_FORGE: process.env.FM_FORGE,
      FM_HARNESS: process.env.FM_HARNESS,
    },
  }),
  branch: process.env.FM_BRANCH || "fm/\${process.env.FM_TASK_ID}",
  baseBranch: process.env.FM_BASE_BRANCH || "main",
});
NODEEOF
)

  # Write the script to a temp file and run it with node.
  local script_file
  script_file=$(mktemp "${TMPDIR:-/tmp}/sandcastle-run.XXXXXX.mjs")
  printf '%s\n' "$sandcastle_script" > "$script_file"

  log_file=$(fm_backend_sandcastle_log_file "$FM_HOME/state" "${4:-}")
  : > "$log_file"

  # Run sandcastle.run() in the background, logging output.
  (
    node "$script_file" >> "$log_file" 2>&1
    local rc=$?
    # Record completion
    printf 'exit_code=%s\n' "$rc" >> "$log_file"
    rm -f "$script_file"
    exit $rc
  ) &

  local sandcastle_pid=$!
  printf '%s' "$sandcastle_pid" > "$pid_file"

  # Echo the worktree path for the caller (fm-spawn.sh uses it as WT).
  printf '%s' "$wt"
}
