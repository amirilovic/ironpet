enum HookScript {
    /// Installed to `~/.ironpet/bin/ironpet-hook`. Usage: `ironpet-hook <cursor|claude|codex|gemini|copilot|pi> <event>`.
    /// Hooks only report status: short timeouts, always exit 0, never block or fail the agent. Chat approvals do not go
    /// through here; they arrive as `session/request_permission` over ACP.
    static let contents = #"""
    #!/bin/bash
    SOURCE="$1"
    EVENT="$2"
    PAYLOAD="$(cat)"
    DIR="${IRONPET_ROOT:-$HOME/.ironpet}"

    # Cursor also runs the Claude Code hooks in ~/.claude/settings.json; its own hooks already report the session.
    if [ "$SOURCE" = "claude" ] && [ -n "${CURSOR_VERSION:-}" ]; then exit 0; fi

    # A chat that ironpet runs over ACP is tracked by the chat itself. Skip it so it is not listed as an external session.
    # Agents that parse stdout (everything except Claude Code) need a JSON object back, even from a hook that does nothing.
    reply() {
      if [ "$SOURCE" = "cursor" ] && [ "$EVENT" = "beforeSubmitPrompt" ]; then printf '{"continue":true}\n'
      elif [ "$SOURCE" != "claude" ]; then printf '{}\n'; fi
    }

    if [ -n "${IRONPET_ACP_RUN:-}" ]; then reply; exit 0; fi

    if [ -r "$DIR/port" ] && [ -r "$DIR/token" ]; then
      printf '%s' "$PAYLOAD" | curl -s --connect-timeout 0.3 -m 1 -o /dev/null -X POST \
        -H "Content-Type: application/json" \
        -H "X-Ironpet-Token: $(cat "$DIR/token")" \
        -H "X-Ironpet-Source: $SOURCE" \
        -H "X-Ironpet-Event: $EVENT" \
        -H "X-Ironpet-Cwd: ${CURSOR_PROJECT_DIR:-$PWD}" \
        -H "X-Ironpet-Term-Program: ${TERM_PROGRAM:-}" \
        -H "X-Ironpet-Iterm-Session: ${ITERM_SESSION_ID:-}" \
        -H "X-Ironpet-Pid: $PPID" \
        --data-binary @- "http://127.0.0.1:$(cat "$DIR/port")/event" >/dev/null 2>&1
    fi

    reply
    exit 0
    """#
}
