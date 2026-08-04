#!/bin/bash
# waybar custom module for AirPods battery, with click-to-connect.
#
#   "custom/airpods": {
#       "exec": "~/.config/waybar/airpods-status.sh",
#       "return-type": "json",
#       "interval": 30,
#       "signal": 11,
#       "on-click": "~/.config/waybar/airpods-status.sh toggle"
#   }
#
# Follows the pattern of the other modules on this box (caffeine-status.sh,
# vpn-status.sh, airdrop-status.sh): the script lives in the project and is
# symlinked into ~/.config/waybar/. The numbers come from daemon/airpodsd,
# which pushes SIGRTMIN+11 whenever they change - the interval is only a
# safety net in case the daemon dies while the bar keeps running.
#
# The module stays on the bar when disconnected, as a clickable "pods --",
# because AirPods hand themselves back to a phone constantly and the whole
# point of the switch is being able to grab them back.
set -u

RUNDIR="${XDG_RUNTIME_DIR:-/tmp}/airpodsd"
STATE_FILE="$RUNDIR/state.json"
CLICK_FILE="$RUNDIR/click.json"

# How long an optimistic "connecting" label survives before we fall back to the
# daemon's view. A cold connect to AirPods a phone is holding takes a few
# attempts, so this has to outlast the retry loop below.
CLICK_TTL=30

emit() { printf '%s\n' "$1"; }

nudge_waybar() { pkill -RTMIN+11 -x waybar 2>/dev/null || true; }

set_click_state() {
  mkdir -p "$RUNDIR" 2>/dev/null || return 0
  printf '{"state":"%s","ts":%s}\n' "$1" "$(date +%s)" > "$CLICK_FILE.tmp" 2>/dev/null \
    && mv "$CLICK_FILE.tmp" "$CLICK_FILE" 2>/dev/null
  nudge_waybar
}

clear_click_state() { rm -f "$CLICK_FILE" 2>/dev/null; nudge_waybar; }

daemon_alive() {
  local pid
  pid="$(jq -r '.pid // empty' "$STATE_FILE" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ── toggle ───────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "toggle" ]]; then
  [[ -r "$STATE_FILE" ]] || exit 0
  addr="$(jq -r '.address // .last_address // empty' "$STATE_FILE" 2>/dev/null)"
  [[ -n "$addr" ]] || exit 0

  if [[ "$(jq -r '.connected' "$STATE_FILE" 2>/dev/null)" == "true" ]]; then
    set_click_state disconnecting
    bluetoothctl disconnect "$addr" >/dev/null 2>&1
    clear_click_state
    exit 0
  fi

  # Connecting is slow and often fails the first time: AirPods hold only one
  # audio link, so while a phone has them the link is won and immediately lost
  # (BlueZ reports br-connection-unknown). Retry a few times rather than making
  # the switch feel dead, but give up rather than fighting the phone forever.
  set_click_state connecting
  (
    for _ in 1 2 3; do
      if timeout 15 bluetoothctl connect "$addr" 2>&1 | grep -q "Connection successful"; then
        clear_click_state
        exit 0
      fi
      sleep 2
    done
    clear_click_state
    command -v notify-send >/dev/null && notify-send -t 4000 "AirPods" \
      "Could not connect. If your phone has them, disconnect there first."
  ) >/dev/null 2>&1 &
  exit 0
fi

# ── status ───────────────────────────────────────────────────────────────────
# If airpodsd died without cleaning up (crash, SIGKILL) the file keeps its last
# reading forever. The timestamp cannot catch that, because a battery level that
# has not changed in an hour is still correct, so check the daemon itself.
if [[ ! -r "$STATE_FILE" ]] || ! daemon_alive; then
  emit '{"text":"pods --","class":"dead","tooltip":"airpodsd not running"}'
  exit 0
fi

# An in-flight click outranks the daemon's view, which is still the pre-click
# truth until the link actually comes up.
if [[ -r "$CLICK_FILE" ]]; then
  click_state="$(jq -r '.state // empty' "$CLICK_FILE" 2>/dev/null)"
  click_ts="$(jq -r '.ts // 0' "$CLICK_FILE" 2>/dev/null)"
  if [[ -n "$click_state" ]] && (( $(date +%s) - click_ts < CLICK_TTL )); then
    case "$click_state" in
      connecting)    emit '{"text":"pods ...","class":"connecting","tooltip":"Connecting to AirPods"}'; exit 0 ;;
      disconnecting) emit '{"text":"pods ...","class":"connecting","tooltip":"Disconnecting AirPods"}'; exit 0 ;;
    esac
  fi
fi

jq -c '
  def pct(c): .battery[c].level;
  def st(c): .battery[c].status;
  def lowest: [.battery[]?.level] | min;

  (.name // .last_name // "AirPods") as $name |

  if .connected != true then
    {text: "pods --", class: "off",
     tooltip: ($name + " disconnected\nclick to connect")}
  else
    (if (pct("left") != null and pct("right") != null) then
       (if pct("left") == pct("right") then "pods \(pct("left"))%"
        else "pods \(pct("left"))/\(pct("right"))%" end)
     elif pct("left") != null then "pods L \(pct("left"))%"
     elif pct("right") != null then "pods R \(pct("right"))%"
     else "pods on" end) as $text |

    ([ (if pct("left")  != null then "left  \(pct("left"))%  (\(st("left")))"   else empty end),
       (if pct("right") != null then "right \(pct("right"))%  (\(st("right")))" else empty end),
       (if pct("case")  != null then "case  \(pct("case"))%  (\(st("case")))"   else empty end),
       (if .ear != null then "ear: \(.ear.primary) / \(.ear.secondary)" else empty end),
       "click to disconnect"
     ] | join("\n")) as $tip |

    ((lowest // 100) as $low |
      if $low <= 10 then "critical"
      elif $low <= 25 then "warning"
      elif ([.battery[]?.status] | any(. == "charging")) then "charging"
      else "ok" end) as $class |

    {text: $text, class: $class, tooltip: ($name + "\n" + $tip)}
  end
' "$STATE_FILE" 2>/dev/null || emit '{"text":"pods --","class":"dead","tooltip":"airpods state unreadable"}'
