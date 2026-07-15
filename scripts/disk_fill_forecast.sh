#!/usr/bin/env bash
# ============================================================================
# SCRIPT: disk_fill_forecast.sh
# DESCRIPTION:
#   Polls disk space usage in a continuous loop (or single execution) and fits
#   a rolling window of space/time samples to project filesystems' ETAs to 100% full.
#   It uses a least-squares linear regression slope over the historical sample window.
#
# PARAMETERS CHECKED:
#   - Filesystem Capacity (df -P -k): Measures percentage and KiB usage.
#   - Time-delta (date +%s): Captures precise intervals between polls.
#   - Growth Slope (KiB/sec): Calculates the rate of growth.
#
# RECOMMENDATIONS & RATIONALE:
#   - If ETA < 24h (ALERT threshold): Triggers critical red alert. Rationale:
#     Running out of disk space causes PostgreSQL to crash immediately (PANIC state)
#     and can corrupt active WAL or files. Immediate intervention is required.
#   - If ETA < 72h: Triggers a warning. Rationale: Gives operators advanced warning
#     to provision storage, run vacuum, or clean up logs before reaching emergency state.
#   - State kept in memory: Avoids writing history to disk. Rationale: Writing to
#     disk would speed up the disk filling process the script is trying to prevent.
#
# USAGE:
#   ./disk_fill_forecast.sh                      # default 60s interval, 10-sample window
#   INTERVAL=30 WINDOW=20 ./disk_fill_forecast.sh # environment overrides
#   ./disk_fill_forecast.sh -i 30 -w 20 -m /var/lib/pgsql -m /pg_wal
# ============================================================================

set -u

INTERVAL="${INTERVAL:-60}"
WINDOW="${WINDOW:-10}"
ALERT="${ALERT:-86400}"
ONESHOT=0
declare -a MOUNTS=()

# ---- arg parsing ---------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -i) INTERVAL="$2"; shift 2 ;;
    -w) WINDOW="$2";   shift 2 ;;
    -a) ALERT="$2";    shift 2 ;;
    -m) MOUNTS+=("$2"); shift 2 ;;
    -1) ONESHOT=1;     shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---- colours (disabled if not a TTY) -------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
  C_DIM=$'\033[2m';  C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_BLD=""; C_RST=""
fi

# ---- rolling history: assoc arrays keyed by mount ------------------------
# TS[mount]   -> space-separated epoch seconds
# USED[mount] -> space-separated used KiB
declare -A TS
declare -A USED
declare -A SIZE     # last known total size (KiB) per mount

# Format a duration in seconds as a human string.
human_eta() {
  local s=$1
  if [ "$s" -lt 0 ]; then echo "-"; return; fi
  local d=$(( s / 86400 ))
  local h=$(( (s % 86400) / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else                      printf '%dm'     "$m"
  fi
}

# Least-squares slope (KiB/sec) of used-space over the stored window for $1.
# Prints "slope" via awk. Also prints intercept-free trend; we only need slope.
slope_kib_per_sec() {
  local mount="$1"
  awk -v ts="${TS[$mount]}" -v us="${USED[$mount]}" '
    BEGIN {
      n = split(ts, T, " ");
      split(us, U, " ");
      if (n < 2) { print "0"; exit }
      # normalise time to first sample to keep numbers small
      t0 = T[1];
      for (i = 1; i <= n; i++) {
        x = T[i] - t0; y = U[i];
        sx += x; sy += y; sxx += x*x; sxy += x*y;
      }
      denom = (n*sxx - sx*sx);
      if (denom == 0) { print "0"; exit }
      slope = (n*sxy - sx*sy) / denom;   # KiB per second
      printf "%.6f", slope;
    }'
}

# Push a new sample into the rolling window for a mount, trimming to WINDOW.
push_sample() {
  local mount="$1" now="$2" used="$3"
  TS[$mount]="${TS[$mount]:-} $now"
  USED[$mount]="${USED[$mount]:-} $used"
  # trim to last WINDOW entries
  TS[$mount]="$(echo "${TS[$mount]}"   | awk -v w="$WINDOW" '{for(i=NF-w+1;i<=NF;i++) if(i>=1) printf "%s ",$i}')"
  USED[$mount]="$(echo "${USED[$mount]}" | awk -v w="$WINDOW" '{for(i=NF-w+1;i<=NF;i++) if(i>=1) printf "%s ",$i}')"
}

# ---- one collection + render pass ----------------------------------------
render() {
  local now; now="$(date +%s)"
  local stamp; stamp="$(date '+%Y-%m-%d %H:%M:%S')"

  # Pull df once. -P = POSIX one-line-per-fs, -k = 1K blocks.
  # Columns: Filesystem 1024-blocks Used Available Capacity Mounted-on
  local df_out
  df_out="$(df -P -k 2>/dev/null | tail -n +2)"

  printf '\n%s%s  disk fill forecast  %s(interval %ss, window %s samples)%s\n' \
         "$C_BLD" "$stamp" "$C_DIM" "$INTERVAL" "$WINDOW" "$C_RST"
  printf '%s%-24s %8s %6s %14s %14s%s\n' \
         "$C_DIM" "MOUNT" "USE%" "GROW" "RATE" "ETA TO FULL" "$C_RST"
  printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------------------------" "$C_RST"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local fs blocks used avail cap mount
    fs="$(   echo "$line" | awk '{print $1}')"
    blocks="$(echo "$line" | awk '{print $2}')"
    used="$( echo "$line" | awk '{print $3}')"
    cap="$(  echo "$line" | awk '{print $5}' | tr -d '%')"
    mount="$(echo "$line" | awk '{print $6}')"

    # skip pseudo / special filesystems
    case "$fs" in tmpfs|devtmpfs|udev|overlay|none|shm) continue ;; esac
    case "$mount" in /dev*|/proc*|/sys*|/run*) continue ;; esac

    # if a mount filter was given, honour it
    if [ "${#MOUNTS[@]}" -gt 0 ]; then
      local keep=0
      for m in "${MOUNTS[@]}"; do [ "$m" = "$mount" ] && keep=1; done
      [ "$keep" -eq 0 ] && continue
    fi

    SIZE[$mount]="$blocks"
    push_sample "$mount" "$now" "$used"

    # compute growth trend
    local slope eta_str grow_str rate_str colour
    slope="$(slope_kib_per_sec "$mount")"

    # decide direction and ETA
    colour="$C_GRN"; grow_str="flat"; rate_str="-"; eta_str="-"
    # awk comparison for float slope
    local growing; growing="$(awk -v s="$slope" 'BEGIN{print (s>0.01)?1:0}')"
    local shrinking; shrinking="$(awk -v s="$slope" 'BEGIN{print (s< -0.01)?1:0}')"

    if [ "$growing" = "1" ]; then
      grow_str="up"
      # human rate: KiB/s -> MiB/hour is friendlier
      rate_str="$(awk -v s="$slope" 'BEGIN{printf "%.1f MiB/h", s*3600/1024}')"
      # seconds to full: (total - used) / slope
      local eta_sec
      eta_sec="$(awk -v total="$blocks" -v used="$used" -v s="$slope" \
                  'BEGIN{ if(s<=0){print -1} else {printf "%d",(total-used)/s} }')"
      if [ "$eta_sec" -ge 0 ] 2>/dev/null; then
        eta_str="$(human_eta "$eta_sec")"
        if   [ "$eta_sec" -lt "$ALERT" ]; then colour="$C_RED"
        elif [ "$eta_sec" -lt $(( ALERT * 3 )) ]; then colour="$C_YEL"
        else colour="$C_GRN"; fi
      fi
    elif [ "$shrinking" = "1" ]; then
      grow_str="down"; colour="$C_DIM"
      rate_str="$(awk -v s="$slope" 'BEGIN{printf "%.1f MiB/h", s*3600/1024}')"
    fi

    printf '%s%-24s %7s%% %6s %14s %14s%s\n' \
           "$colour" "$mount" "$cap" "$grow_str" "$rate_str" "$eta_str" "$C_RST"
  done <<< "$df_out"
}

# ---- main loop -----------------------------------------------------------
trap 'echo; echo "stopped."; exit 0' INT TERM

if [ "$ONESHOT" -eq 1 ]; then
  render          # note: first render has no history -> no ETA
  exit 0
fi

echo "Monitoring disk fill rate. Ctrl-C to stop."
echo "First ETA appears after the 2nd sample (need >=2 points to fit a trend)."
while true; do
  render
  sleep "$INTERVAL"
done
