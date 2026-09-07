#!/usr/bin/env bash

# Benchmark DNS-over-TLS (DoT, RFC 7858) on port 853.
# Requires BIND dig 9.18+ (this host has 9.20).

DNS_SERVERS=(
    "138.97.141.5" # ISP DNS
    "190.92.0.5"   # ISP DNS
    "1.1.1.1"      # Cloudflare
    "1.0.0.1"
    "1.1.1.2"
    "1.0.0.2"
    "1.1.1.3"
    "1.0.0.3"
    "8.8.8.8" # Google
    "8.8.4.4"
    "9.9.9.9" # Quad9
    "149.112.112.112"
    "45.90.28.29" # NextDNS
    "45.90.30.29"
    "76.76.2.22"     # controld
    "208.67.222.222" # OpenDNS
    "208.67.220.220"
    "94.140.14.14" # AdGuard
    "94.140.15.15"
)

TEST_DOMAIN="google.com"
TEST_COUNT=5
INTERVAL=10

declare -a RESULTS

echo "DoT Benchmark Starting (DNS-over-TLS, port 853)..."
echo "Each server will be tested ${TEST_COUNT} times with ${INTERVAL}s between tests."
echo

for dns in "${DNS_SERVERS[@]}"; do
    echo "Testing ${dns} (DoT)..."

    total=0
    success=0

    for ((i = 1; i <= TEST_COUNT; i++)); do
        query_time=$(dig +tls @"$dns" "$TEST_DOMAIN" +stats +tries=1 +timeout=5 |
            awk '/Query time:/ {print $4}')

        if [[ "$query_time" =~ ^[0-9]+$ ]]; then
            echo "  Test ${i}: ${query_time} ms"
            total=$((total + query_time))
            success=$((success + 1))
        else
            echo "  Test ${i}: FAILED"
        fi

        if [ "$i" -lt "$TEST_COUNT" ]; then
            sleep "$INTERVAL"
        fi
    done

    if [ "$success" -gt 0 ]; then
        avg=$(awk "BEGIN {printf \"%.2f\", $total/$success}")
        RESULTS+=("${avg} ${dns}")
        echo "  Average: ${avg} ms"
    else
        RESULTS+=("99999 ${dns}")
        echo "  Average: FAILED"
    fi

    echo
done

echo
echo "=========================================="
echo "Average DoT Response Time Per DNS Server"
echo "=========================================="

printf '%s\n' "${RESULTS[@]}" | sort -n | while read -r avg dns; do
    if [[ "$avg" == "99999" ]]; then
        printf "%-15s FAILED\n" "$dns"
    else
        printf "%-15s %8.2f ms\n" "$dns" "$avg"
    fi
done

echo
echo "=========================================="
echo "Top 3 Fastest DoT Servers"
echo "=========================================="

printf '%s\n' "${RESULTS[@]}" | sort -n | grep -v "^99999" | head -3 | while read -r avg dns; do
    printf "%-15s %8.2f ms\n" "$dns" "$avg"
done
