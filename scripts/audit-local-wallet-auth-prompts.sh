#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/audit-local-wallet-auth-prompts.sh --start "YYYY-MM-DD HH:MM:SS" --end "YYYY-MM-DD HH:MM:SS" [--dry-run]
  scripts/audit-local-wallet-auth-prompts.sh --duration <N[s|m|h|d]> [--dry-run]

Summarizes macOS unified-log activation evidence for Local Wallet and the
CoreAuthentication UI during an explicit observation window.

This helper is read-only. It does not automate Touch ID, does not inspect
Keychain contents, and never prints raw unified-log messages or secret material.
Its counts are observational UI evidence, not proof that authentication
succeeded and not signed runtime proof.

Options:
  --start <timestamp>  Local start time, for example "2026-08-16 15:00:00".
  --end <timestamp>    Local end time, using the same format as --start.
  --duration <value>   Relative window accepted by log(1), for example 30s or 5m.
  --dry-run            Validate arguments and describe the metadata-only queries.
  -h, --help           Show this help.
USAGE
}

die_usage() {
  echo "error: $*" >&2
  echo >&2
  usage >&2
  exit 64
}

START_TIME=""
END_TIME=""
DURATION=""
DRY_RUN=false

while (($# > 0)); do
  case "$1" in
    --start)
      (($# >= 2)) || die_usage "--start requires a timestamp"
      START_TIME="$2"
      shift 2
      ;;
    --end)
      (($# >= 2)) || die_usage "--end requires a timestamp"
      END_TIME="$2"
      shift 2
      ;;
    --duration)
      (($# >= 2)) || die_usage "--duration requires a value"
      DURATION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

if [[ -n "$DURATION" ]]; then
  [[ -z "$START_TIME" && -z "$END_TIME" ]] \
    || die_usage "use either --duration or --start/--end, not both"
  [[ "$DURATION" =~ ^[1-9][0-9]*[smhd]$ ]] \
    || die_usage "--duration must match N[s|m|h|d], with N greater than zero"
  TIME_ARGS=(--last "$DURATION")
  WINDOW_DESCRIPTION="last $DURATION"
else
  [[ -n "$START_TIME" && -n "$END_TIME" ]] \
    || die_usage "provide both --start and --end, or provide --duration"
  TIMESTAMP_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
  [[ "$START_TIME" =~ $TIMESTAMP_PATTERN ]] \
    || die_usage "--start must use YYYY-MM-DD HH:MM:SS"
  [[ "$END_TIME" =~ $TIMESTAMP_PATTERN ]] \
    || die_usage "--end must use YYYY-MM-DD HH:MM:SS"

  START_EPOCH="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$START_TIME" '+%s' 2>/dev/null)" \
    || die_usage "--start is not a valid local timestamp"
  END_EPOCH="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$END_TIME" '+%s' 2>/dev/null)" \
    || die_usage "--end is not a valid local timestamp"
  ((START_EPOCH < END_EPOCH)) || die_usage "--start must be earlier than --end"

  TIME_ARGS=(--start "$START_TIME" --end "$END_TIME")
  WINDOW_DESCRIPTION="$START_TIME through $END_TIME (local time)"
fi

LOCAL_WALLET_ACTIVATION_PREDICATE='((process == "Local Wallet") OR (process == "runningboardd") OR (process == "launchservicesd") OR (process == "WindowServer")) AND ((process == "Local Wallet") OR (eventMessage CONTAINS[c] "Local Wallet") OR (eventMessage CONTAINS[c] "ai.ethereum.localwallet")) AND ((eventMessage CONTAINS[c] "activat") OR (eventMessage CONTAINS[c] "foreground") OR (eventMessage CONTAINS[c] "launch"))'
AUTH_UI_ACTIVATION_PREDICATE='((process CONTAINS[c] "CoreAuthenticationUI") OR (process CONTAINS[c] "LocalAuthenticationRemoteService") OR (process CONTAINS[c] "LocalAuthenticationUI") OR (eventMessage CONTAINS[c] "CoreAuthenticationUI") OR (eventMessage CONTAINS[c] "LocalAuthenticationRemoteService")) AND ((eventMessage CONTAINS[c] "activat") OR (eventMessage CONTAINS[c] "present") OR (eventMessage CONTAINS[c] "appear") OR (eventMessage CONTAINS[c] "launch") OR (eventMessage CONTAINS[c] "spawn") OR (eventMessage CONTAINS[c] "evaluation"))'

echo "Local Wallet authentication prompt audit"
echo "Observation window: $WINDOW_DESCRIPTION"
echo "Safety: read-only metadata counts; raw log messages and Keychain contents are never printed."
echo "Limitation: this helper does not automate Touch ID and does not provide signed runtime proof."

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: would count Local Wallet activation evidence records."
  echo "Dry run: would count CoreAuthentication UI activation evidence records."
  echo "Dry run complete; no unified logs were read."
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || die_usage "unified-log auditing requires macOS"
[[ -x /usr/bin/log ]] || die_usage "/usr/bin/log is unavailable"

count_matching_records() {
  local predicate="$1"
  /usr/bin/log show "${TIME_ARGS[@]}" --style ndjson --info --predicate "$predicate" 2>/dev/null \
    | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }'
}

LOCAL_WALLET_ACTIVATIONS="$(count_matching_records "$LOCAL_WALLET_ACTIVATION_PREDICATE")"
AUTH_UI_ACTIVATIONS="$(count_matching_records "$AUTH_UI_ACTIVATION_PREDICATE")"

echo "Local Wallet activation evidence records: $LOCAL_WALLET_ACTIVATIONS"
echo "CoreAuthentication UI activation evidence records: $AUTH_UI_ACTIVATIONS"
echo "Interpretation: counts are matching log records, not biometric prompt or success counts."
echo "For a useful manual audit, exercise only Local Wallet during the observation window."
