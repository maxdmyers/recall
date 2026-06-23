#!/usr/bin/env bash
# recall :: dashboard generator
# Reads the vault and bakes a self-contained dashboard.html (no server, no JS
# fetch — file:// can't fetch). Pure shell. Run on demand or nightly via distill.
#   usage: build-dashboard.sh [output.html]

set -uo pipefail

AOS="${RECALL_VAULT:-$HOME/Documents/Vault/recall}"
SESS="$AOS/sessions"
KN="$AOS/knowledge"
PROP="$AOS/inbox/proposals.md"
LOG="$AOS/.distill.log"
OUT="${1:-$AOS/dashboard.html}"

[ -d "$AOS" ] || { echo "build-dashboard: vault not found at $AOS" >&2; exit 1; }

field(){ grep -m1 "^$1:" "$2" 2>/dev/null | sed "s/^$1: *//"; }
esc(){ printf '%s' "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
nobt(){ printf '%s' "${1:-}" | tr -d '`'; }

# relative time from a YYYY-MM-DD or full ISO-Z timestamp
reltime(){
  local d="$1" epoch now days
  case "$d" in
    *T*) epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s 2>/dev/null);;
    ????-??-??) epoch=$(date -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null);;
    *) echo "${d:-—}"; return;;
  esac
  [ -z "$epoch" ] && { echo "$d"; return; }
  now=$(date +%s); days=$(( (now - epoch) / 86400 ))
  if   [ "$days" -le 0 ]; then echo "today"
  elif [ "$days" -eq 1 ]; then echo "yesterday"
  else echo "${days}d ago"; fi
}
daysago(){
  local d="$1" epoch
  case "$d" in
    *T*) epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s 2>/dev/null);;
    ????-??-??) epoch=$(date -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null);;
    *) echo 9999; return;;
  esac
  [ -z "$epoch" ] && { echo 9999; return; }
  echo $(( ( $(date +%s) - epoch ) / 86400 ))
}

# ---------- stats ----------
S_TOTAL=$(ls "$SESS"/*.md 2>/dev/null | wc -l | tr -d ' ')
S_UNDIST=$(grep -rl '^distilled: false' "$SESS" 2>/dev/null | wc -l | tr -d ' ')
S_DIST=$(( S_TOTAL - S_UNDIST ))
N_NOTES=$(find "$KN" -name '*.md' ! -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
N_PROJ=$(find "$KN/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
P_TOTAL=$(grep -c '^## ' "$PROP" 2>/dev/null || echo 0)
P_IMPL=$(grep -c 'status:.*implemented' "$PROP" 2>/dev/null || echo 0)
P_PEND=$(( P_TOTAL - P_IMPL ))

# ---------- schedule ----------
JOBLINE=$(launchctl list 2>/dev/null | grep 'com\.recall\.distill')
J_PID=$(printf '%s' "$JOBLINE" | awk '{print $1}')
J_EXIT=$(printf '%s' "$JOBLINE" | awk '{print $2}')
[ -n "${J_EXIT:-}" ] || J_EXIT="?"
LAST_DONE=$(grep ' done$' "$LOG" 2>/dev/null | tail -1 | awk '{print $1}')
LAST_LINE=$(tail -1 "$LOG" 2>/dev/null)
if [ "$J_EXIT" = "0" ]; then HEALTH_CLS="ok"; HEALTH_TXT="healthy";
elif [ "$J_EXIT" = "?" ]; then HEALTH_CLS="warn"; HEALTH_TXT="not loaded";
else HEALTH_CLS="bad"; HEALTH_TXT="exit $J_EXIT"; fi

# ---------- recent sessions ----------
SESSION_ROWS=""
while IFS=$'\t' read -r upd proj dis; do
  [ -z "$upd" ] && continue
  rel=$(reltime "$upd")
  if [ "$dis" = "true" ]; then badge='<span class="chip done">distilled</span>';
  else badge='<span class="chip pending">queued</span>'; fi
  SESSION_ROWS="$SESSION_ROWS<tr><td class=\"proj\">$(esc "$proj")</td><td class=\"when\">$rel</td><td class=\"st\">$badge</td></tr>"
done < <(
  for f in "$SESS"/*.md; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(field updated "$f")" "$(field project "$f")" "$(field distilled "$f")"
  done | sort -r | head -12
)

# ---------- recent notes ----------
NOTE_ROWS=""
while IFS=$'\t' read -r upd name scope path; do
  [ -z "$name" ] && continue
  summary=$(grep -rh "\[\[$name\]\]" "$KN"/global/INDEX.md "$KN"/projects/*/INDEX.md 2>/dev/null | head -1 | sed 's/.*—[[:space:]]*//')
  rel=$(reltime "$upd"); d=$(daysago "$upd")
  new=""; [ "$d" -le 3 ] && new='<span class="new">new</span>'
  NOTE_ROWS="$NOTE_ROWS<div class=\"note\"><div class=\"nh\"><span class=\"nname\">$(esc "$name")</span><span class=\"nscope\">$(esc "$scope")</span>$new<span class=\"nwhen\">$rel</span></div><div class=\"nsum\">$(esc "${summary:-—}")</div></div>"
done < <(
  for f in $(find "$KN" -name '*.md' ! -name 'INDEX.md' 2>/dev/null); do
    name=$(basename "$f" .md)
    case "$f" in
      */global/*) scope="global";;
      *) scope=$(basename "$(dirname "$f")");;
    esac
    printf '%s\t%s\t%s\t%s\n' "$(field updated "$f")" "$name" "$scope" "$f"
  done | sort -r | head -9
)

# ---------- proposals (the inbox) ----------
PROP_CARDS=""
while IFS=$'\t' read -r name seen what scope conf st; do
  [ -z "$name" ] && continue
  case "$st" in
    *implemented*) scls="done"; slabel="implemented";;
    *) scls="pending"; slabel="awaiting approval";;
  esac
  case "$conf" in high) ccls="c-high";; med) ccls="c-med";; *) ccls="c-low";; esac
  PROP_CARDS="$PROP_CARDS<div class=\"prop $scls\"><div class=\"ph\"><span class=\"pname\">$(esc "$(nobt "$name")")</span><span class=\"pst $scls\">$slabel</span></div><div class=\"pwhat\">$(esc "$(nobt "$what")")</div><div class=\"pmeta\"><span class=\"tag\">$(esc "$scope")</span><span class=\"tag\"><span class=\"dot $ccls\"></span>$(esc "$conf") confidence</span><span class=\"tag faint\">$(esc "$seen")</span></div></div>"
done < <(
  awk '
    function flush(){ if(n!=""){ printf "%s\t%s\t%s\t%s\t%s\t%s\n", n,seen,what,scope,conf,st } }
    /^## /      { flush(); n=substr($0,4); seen=what=scope=conf=st=""; next }
    /^- seen:/       { s=$0; sub(/^- seen:[[:space:]]*/,"",s); seen=s }
    /^- what:/       { s=$0; sub(/^- what:[[:space:]]*/,"",s); what=s }
    /^- scope:/      { s=$0; sub(/^- scope:[[:space:]]*/,"",s); scope=s }
    /^- confidence:/ { s=$0; sub(/^- confidence:[[:space:]]*/,"",s); conf=s }
    /^- status:/     { s=$0; sub(/^- status:[[:space:]]*/,"",s); st=s }
    END{ flush() }
  ' "$PROP" 2>/dev/null
)
[ -n "$PROP_CARDS" ] || PROP_CARDS='<div class="empty">inbox empty — no proposals yet</div>'

# ---------- knowledge by area ----------
AREA_ROWS=""
gc=$(find "$KN/global" -name '*.md' ! -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
maxc=$gc
for d in "$KN"/projects/*/; do
  c=$(find "$d" -name '*.md' ! -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
  [ "$c" -gt "$maxc" ] && maxc=$c
done
[ "$maxc" -lt 1 ] && maxc=1
bar(){ printf '%s' "$(( $1 * 100 / maxc ))"; }
AREA_ROWS="$AREA_ROWS<div class=\"area\"><span class=\"al\">global</span><span class=\"abar\"><i style=\"width:$(bar "$gc")%\"></i></span><span class=\"ac\">$gc</span></div>"
for d in "$KN"/projects/*/; do
  [ -d "$d" ] || continue
  nm=$(basename "$d"); c=$(find "$d" -name '*.md' ! -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
  AREA_ROWS="$AREA_ROWS<div class=\"area\"><span class=\"al\">$(esc "$nm")</span><span class=\"abar\"><i style=\"width:$(bar "$c")%\"></i></span><span class=\"ac\">$c</span></div>"
done

HL_Q=""; [ "$S_UNDIST" -gt 0 ] && HL_Q=" hl"
HL_P=""; [ "$P_PEND" -gt 0 ] && HL_P=" hl"
GEN=$(date '+%a %b %-d, %-I:%M %p')
LAST_DONE_REL=$( [ -n "$LAST_DONE" ] && reltime "$LAST_DONE" || echo "never" )

# ---------- emit ----------
cat > "$OUT" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>recall · dashboard</title>
<style>
  :root{
    --bg:#0b0d12; --bg-2:#11141c; --panel:#161a24; --line:#232938; --line-2:#2e3650;
    --ink:#e7eaf3; --muted:#8b93a7; --faint:#5b6478;
    --accent:#a78bfa; --accent-2:#5eead4; --amber:#fbbf24; --rose:#fb7185; --green:#4ade80;
    --mono:ui-monospace,"SF Mono","JetBrains Mono",Menlo,monospace;
    --sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Inter,sans-serif;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--ink);font-family:var(--sans);-webkit-font-smoothing:antialiased;line-height:1.5}
  body::before{content:"";position:fixed;inset:0;z-index:0;pointer-events:none;
    background:radial-gradient(900px 600px at 90% -10%,rgba(167,139,250,.10),transparent 60%),
               radial-gradient(700px 500px at -5% 110%,rgba(94,234,212,.06),transparent 55%)}
  .wrap{position:relative;z-index:1;max-width:1180px;margin:0 auto;padding:clamp(22px,4vw,46px) clamp(18px,4vw,40px) 80px}

  .topbar{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;flex-wrap:wrap;margin-bottom:32px;
    padding-bottom:22px;border-bottom:1px solid var(--line)}
  .brand{font-family:var(--mono);font-size:clamp(30px,5vw,44px);font-weight:700;letter-spacing:-.04em}
  .brand .dot{color:var(--accent)}
  .brand .sub{display:block;font-family:var(--sans);font-size:13px;font-weight:400;color:var(--muted);letter-spacing:0;margin-top:4px}
  .tmeta{text-align:right;font-family:var(--mono);font-size:12px;color:var(--faint);line-height:1.9}
  .pill{display:inline-flex;align-items:center;gap:7px;border:1px solid var(--line-2);border-radius:999px;padding:5px 12px;color:var(--ink)}
  .pill .dot{width:8px;height:8px;border-radius:50%}
  .pill.ok .dot{background:var(--green)} .pill.warn .dot{background:var(--amber)} .pill.bad .dot{background:var(--rose)}

  .stats{display:grid;grid-template-columns:repeat(6,1fr);gap:12px;margin-bottom:26px}
  @media(max-width:920px){.stats{grid-template-columns:repeat(3,1fr)}}
  @media(max-width:520px){.stats{grid-template-columns:repeat(2,1fr)}}
  .stat{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px 16px}
  .stat .big{font-family:var(--mono);font-size:clamp(26px,3.4vw,36px);font-weight:700;letter-spacing:-.03em}
  .stat .lbl{color:var(--muted);font-size:12px;margin-top:4px}
  .stat.hl{border-color:var(--line-2);box-shadow:inset 0 0 0 1px rgba(167,139,250,.18)}
  .stat.hl .big{color:var(--accent)}

  .grid2{display:grid;grid-template-columns:1.25fr .9fr;gap:18px}
  @media(max-width:880px){.grid2{grid-template-columns:1fr}}
  .panel{background:linear-gradient(180deg,var(--panel),var(--bg-2));border:1px solid var(--line);border-radius:14px;padding:20px 22px;margin-bottom:18px}
  .panel>h2{font-size:13px;font-family:var(--mono);letter-spacing:.16em;text-transform:uppercase;color:var(--faint);
    display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}
  .panel>h2 .count{color:var(--accent)}

  table{width:100%;border-collapse:collapse;font-size:14px}
  td{padding:9px 6px;border-bottom:1px solid var(--line);vertical-align:middle}
  tr:last-child td{border-bottom:none}
  td.proj{font-weight:600}
  td.when{color:var(--muted);font-family:var(--mono);font-size:12.5px;white-space:nowrap}
  td.st{text-align:right;white-space:nowrap}
  .chip{font-family:var(--mono);font-size:11px;border-radius:999px;padding:3px 9px;border:1px solid var(--line-2)}
  .chip.done{color:var(--accent-2);border-color:rgba(94,234,212,.3)}
  .chip.pending{color:var(--amber);border-color:rgba(251,191,36,.3)}

  .note{padding:11px 0;border-bottom:1px solid var(--line)}
  .note:last-child{border-bottom:none}
  .nh{display:flex;align-items:center;gap:9px;flex-wrap:wrap}
  .nname{font-family:var(--mono);font-size:13.5px;color:var(--accent-2);font-weight:600}
  .nscope{font-family:var(--mono);font-size:10.5px;color:var(--faint);border:1px solid var(--line);border-radius:999px;padding:1px 8px}
  .new{font-family:var(--mono);font-size:10px;color:var(--accent);border:1px solid rgba(167,139,250,.4);border-radius:999px;padding:1px 7px;letter-spacing:.05em}
  .nwhen{margin-left:auto;font-family:var(--mono);font-size:11.5px;color:var(--faint)}
  .nsum{color:var(--muted);font-size:13px;margin-top:3px;max-width:62ch}

  .prop{border:1px solid var(--line);border-radius:11px;padding:14px 16px;margin-bottom:11px;background:rgba(255,255,255,.012)}
  .prop.pending{border-left:2px solid var(--amber)}
  .prop.done{border-left:2px solid var(--accent-2);opacity:.72}
  .ph{display:flex;align-items:center;justify-content:space-between;gap:10px}
  .pname{font-family:var(--mono);font-weight:600;font-size:14px}
  .pst{font-family:var(--mono);font-size:10.5px;border-radius:999px;padding:2px 9px;letter-spacing:.03em;white-space:nowrap}
  .pst.pending{color:var(--amber);border:1px solid rgba(251,191,36,.35)}
  .pst.done{color:var(--accent-2);border:1px solid rgba(94,234,212,.3)}
  .pwhat{color:var(--muted);font-size:13px;margin:8px 0 12px;line-height:1.5}
  .pmeta{display:flex;flex-wrap:wrap;gap:8px}
  .tag{font-family:var(--mono);font-size:11px;color:var(--ink);border:1px solid var(--line-2);border-radius:999px;padding:3px 10px;display:inline-flex;align-items:center;gap:6px}
  .tag.faint{color:var(--faint)}
  .dot{width:7px;height:7px;border-radius:50%}
  .c-high{background:var(--green)} .c-med{background:var(--amber)} .c-low{background:var(--rose)}
  .empty{color:var(--faint);font-size:13px;font-style:italic;padding:8px 0}

  .area{display:flex;align-items:center;gap:12px;padding:7px 0}
  .al{font-family:var(--mono);font-size:12.5px;width:120px;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .abar{flex:1;height:6px;background:var(--bg);border-radius:999px;overflow:hidden;border:1px solid var(--line)}
  .abar i{display:block;height:100%;background:linear-gradient(90deg,var(--accent),var(--accent-2))}
  .ac{font-family:var(--mono);font-size:12px;color:var(--muted);width:24px;text-align:right}

  .logline{font-family:var(--mono);font-size:11.5px;color:var(--faint);margin-top:10px;word-break:break-all}
  footer{margin-top:34px;text-align:center;font-family:var(--mono);font-size:11px;color:var(--faint);letter-spacing:.08em}
</style>
</head>
<body>
<div class="wrap">

  <div class="topbar">
    <div class="brand">recall<span class="dot">.</span><span class="sub">memory &amp; learning system — live state</span></div>
    <div class="tmeta">
      <span class="pill $HEALTH_CLS"><span class="dot"></span>distill · $HEALTH_TXT</span><br>
      updated $GEN<br>
      last distill: $LAST_DONE_REL
    </div>
  </div>

  <div class="stats">
    <div class="stat"><div class="big">$S_TOTAL</div><div class="lbl">sessions captured</div></div>
    <div class="stat"><div class="big">$S_DIST</div><div class="lbl">distilled</div></div>
    <div class="stat${HL_Q}"><div class="big">$S_UNDIST</div><div class="lbl">in queue</div></div>
    <div class="stat"><div class="big">$N_NOTES</div><div class="lbl">knowledge notes</div></div>
    <div class="stat"><div class="big">$N_PROJ</div><div class="lbl">projects</div></div>
    <div class="stat${HL_P}"><div class="big">$P_PEND</div><div class="lbl">proposals pending</div></div>
  </div>

  <div class="grid2">
    <div>
      <div class="panel">
        <h2>Recent sessions <span class="count">$S_TOTAL total</span></h2>
        <table>$SESSION_ROWS</table>
      </div>
      <div class="panel">
        <h2>Recently distilled knowledge <span class="count">$N_NOTES notes</span></h2>
        $NOTE_ROWS
      </div>
    </div>
    <div>
      <div class="panel">
        <h2>Inbox · proposals <span class="count">$P_PEND pending</span></h2>
        $PROP_CARDS
      </div>
      <div class="panel">
        <h2>Knowledge by area</h2>
        $AREA_ROWS
      </div>
      <div class="panel">
        <h2>Distill schedule</h2>
        <div class="area"><span class="al">status</span><span style="flex:1"></span><span class="ac" style="width:auto"><span class="pill $HEALTH_CLS"><span class="dot"></span>$HEALTH_TXT</span></span></div>
        <div class="area"><span class="al">last run</span><span style="flex:1"></span><span class="ac" style="width:auto;color:var(--muted)">$LAST_DONE_REL</span></div>
        <div class="area"><span class="al">cadence</span><span style="flex:1"></span><span class="ac" style="width:auto;color:var(--muted)">nightly · 7pm</span></div>
        <div class="logline">$(esc "${LAST_LINE:-no log yet}")</div>
      </div>
    </div>
  </div>

  <footer>recall · capture → distill → retrieve → gate · generated $GEN</footer>
</div>
</body>
</html>
EOF

echo "dashboard → $OUT"
