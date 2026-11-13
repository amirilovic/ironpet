enum HookScript {
    /// Installed to `~/.ironpet/bin/ironpet-hook`. Usage: `ironpet-hook <cursor|claude> <event>`.
    /// Status events never block or fail the agent: short timeouts, always exit 0.
    /// Gate events only act for agents the pet started (IRONPET_RUN_ID set) and block until the user decides.
    static let contents = #"""
    #!/bin/bash
    SOURCE="$1"
    EVENT="$2"
    PAYLOAD="$(cat)"
    DIR="$HOME/.ironpet"

    # Cursor also runs the Claude Code hooks in ~/.claude/settings.json; its own hooks already report the session.
    if [ "$SOURCE" = "claude" ] && [ -n "${CURSOR_VERSION:-}" ]; then exit 0; fi

    GATE=0
    case "$EVENT" in
      beforeShellExecution|preToolUse|beforeMCPExecution) [ "$SOURCE" = "cursor" ] && GATE=1 ;;
    esac
    if [ "$SOURCE" = "claude" ] && [ "$EVENT" = "PreToolUse" ] && [ -n "${IRONPET_RUN_ID:-}" ]; then GATE=1; fi

    if [ "$GATE" = 1 ]; then
      if [ -z "${IRONPET_RUN_ID:-}" ]; then printf '{}\n'; exit 0; fi
      RESPONSE=""
      if [ -r "$DIR/port" ] && [ -r "$DIR/token" ]; then
        RESPONSE="$(printf '%s' "$PAYLOAD" | curl -s --connect-timeout 1 --max-time 3600 -X POST \
          -H "Content-Type: application/json" \
          -H "X-Ironpet-Token: $(cat "$DIR/token")" \
          -H "X-Ironpet-Source: $SOURCE" \
          -H "X-Ironpet-Event: $EVENT" \
          -H "X-Ironpet-Run-Id: $IRONPET_RUN_ID" \
          --data-binary @- "http://127.0.0.1:$(cat "$DIR/port")/approval" 2>/dev/null)"
      fi
      if [ -n "$RESPONSE" ]; then
        printf '%s\n' "$RESPONSE"
      elif [ "$SOURCE" = "claude" ]; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"ironpet is not running"}}\n'
      else
        printf '{"permission":"deny","user_message":"ironpet is not running"}\n'
      fi
      exit 0
    fi

    if [ -r "$DIR/port" ] && [ -r "$DIR/token" ]; then
      printf '%s' "$PAYLOAD" | curl -s --connect-timeout 0.3 -m 1 -o /dev/null -X POST \
        -H "Content-Type: application/json" \
        -H "X-Ironpet-Token: $(cat "$DIR/token")" \
        -H "X-Ironpet-Source: $SOURCE" \
        -H "X-Ironpet-Event: $EVENT" \
        -H "X-Ironpet-Cwd: ${CURSOR_PROJECT_DIR:-$PWD}" \
        -H "X-Ironpet-Term-Program: ${TERM_PROGRAM:-}" \
        -H "X-Ironpet-Iterm-Session: ${ITERM_SESSION_ID:-}" \
        -H "X-Ironpet-Run-Id: ${IRONPET_RUN_ID:-}" \
        -H "X-Ironpet-Pid: $PPID" \
        --data-binary @- "http://127.0.0.1:$(cat "$DIR/port")/event" >/dev/null 2>&1
    fi

    if [ "$SOURCE" = "cursor" ]; then
      if [ "$EVENT" = "beforeSubmitPrompt" ]; then printf '{"continue":true}\n'; else printf '{}\n'; fi
    fi
    exit 0
    """#
}
