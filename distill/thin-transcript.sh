#!/usr/bin/env bash
# recall :: transcript thinner
# Turns a raw Claude Code transcript JSONL into a compact narrative:
#   keeps user msgs + assistant text + tool names/inputs,
#   drops thinking, tool-result bodies, and other bookkeeping.
# Token-control step so distill reads cheap narratives, not raw JSONL.
# Usage: thin-transcript.sh <transcript.jsonl>

set -uo pipefail
F="${1:?usage: thin-transcript.sh <transcript.jsonl>}"
[ -f "$F" ] || { echo "(transcript not found: $F)"; exit 0; }

jq -r '
  def clip(n): if (.|length) > n then .[0:n] + "…" else . end;
  if .type == "user" then
    (.message.content) as $c
    | if   ($c|type) == "string" then "USER: " + ($c|clip(700))
      elif ($c|type) == "array"  then
        ($c[] | if   .type == "text"        then "USER: " + (.text|clip(700))
                elif .type == "tool_result" then empty
                else empty end)
      else empty end
  elif .type == "assistant" then
    (.message.content[]?
      | if   .type == "text"     then "ASSISTANT: " + (.text|clip(900))
        elif .type == "tool_use" then "TOOL[" + .name + "]: " + ((.input|tostring)|clip(200))
        else empty end)
  else empty end
' "$F" 2>/dev/null
