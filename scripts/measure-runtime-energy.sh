#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s <new-output-file> <candidate-sha-or-unknown>\n' "$0" >&2
    exit 2
fi

OUTPUT_PATH=$1
CANDIDATE_SHA=$2
case "$CANDIDATE_SHA" in
    unknown) ;;
    *)
        case "$CANDIDATE_SHA" in
            *[!0-9a-fA-F]*|'') printf 'Candidate must be a 40-character hex SHA or unknown.\n' >&2; exit 2 ;;
        esac
        if [ "${#CANDIDATE_SHA}" -ne 40 ]; then
            printf 'Candidate must be a 40-character hex SHA or unknown.\n' >&2
            exit 2
        fi
        ;;
esac

if [ -e "$OUTPUT_PATH" ]; then
    printf 'Output file already exists: %s\n' "$OUTPUT_PATH" >&2
    exit 2
fi

OUTPUT_DIR=$(dirname -- "$OUTPUT_PATH")
mkdir -p "$OUTPUT_DIR"
{
    printf '# candidate_sha=%s\n' "$CANDIDATE_SHA"
    printf '# sampler=powermetrics cpu_power; system-wide estimated subsystem power, not per-app attribution\n'
    printf '# sample_rate_ms=1000\n# sample_count=300\n'
    printf '# run only during the matching idle scenario; do not use --show-process-energy\n'
} > "$OUTPUT_PATH"

/usr/bin/powermetrics \
    --samplers cpu_power \
    --sample-rate 1000 \
    --sample-count 300 \
    --show-usage-summary >> "$OUTPUT_PATH"

printf 'System energy samples saved to %s\n' "$OUTPUT_PATH"
