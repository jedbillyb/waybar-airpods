#!/bin/bash
# waybar custom module for AirPods battery. Emits one JSON object.
#
#   "custom/airpods": {
#       "exec": "~/.config/waybar/airpods-status.sh",
#       "return-type": "json",
#       "interval": 30,
#       "signal": 11
#   }
#
# Follows the pattern of the other modules on this box (caffeine-status.sh,
# vpn-status.sh, airdrop-status.sh): the script lives in the project and is
# symlinked into ~/.config/waybar/. The real work is done by daemon/airpodsd,
# which pushes SIGRTMIN+11 whenever the numbers change - the interval is only
# a safety net in case the daemon dies while the bar keeps running.
set -u

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/airpodsd/state.json"

# No daemon or no AirPods: emit empty text so waybar hides the module entirely.
if [[ ! -r "$STATE_FILE" ]]; then
  echo '{"text":"","tooltip":"airpodsd not running"}'
  exit 0
fi

# If airpodsd died without cleaning up (crash, SIGKILL) the file keeps its last
# reading forever. The timestamp cannot catch that, because a battery level that
# has not changed in an hour is still correct, so check the daemon itself.
DAEMON_PID="$(jq -r '.pid // empty' "$STATE_FILE" 2>/dev/null)"
if [[ -z "$DAEMON_PID" ]] || ! kill -0 "$DAEMON_PID" 2>/dev/null; then
  echo '{"text":"","tooltip":"airpodsd not running"}'
  exit 0
fi

jq -r '
  def pct(c): .battery[c].level;
  def st(c): .battery[c].status;
  def lowest: [.battery[]?.level] | min;

  if .connected != true then
    {text: "", tooltip: "AirPods disconnected"}
  else
    # Bar text stays short: both buds, or a single number when they match.
    (if (pct("left") != null and pct("right") != null) then
       (if pct("left") == pct("right") then "pods \(pct("left"))%"
        else "pods \(pct("left"))/\(pct("right"))%" end)
     elif pct("left") != null then "pods L \(pct("left"))%"
     elif pct("right") != null then "pods R \(pct("right"))%"
     else "pods" end) as $text |

    ([ (if pct("left")  != null then "left  \(pct("left"))%  (\(st("left")))"   else empty end),
       (if pct("right") != null then "right \(pct("right"))%  (\(st("right")))" else empty end),
       (if pct("case")  != null then "case  \(pct("case"))%  (\(st("case")))"   else empty end),
       (if .ear != null then "ear: \(.ear.primary) / \(.ear.secondary)" else empty end)
     ] | join("\n")) as $tip |

    ((lowest // 100) as $low |
      if $low <= 10 then "critical"
      elif $low <= 25 then "warning"
      elif ([.battery[]?.status] | any(. == "charging")) then "charging"
      else "ok" end) as $class |

    {text: $text, tooltip: ((.name // "AirPods") + "\n" + $tip), class: $class}
  end
' "$STATE_FILE" 2>/dev/null | jq -c . 2>/dev/null || echo '{"text":"","tooltip":"airpods state unreadable"}'
