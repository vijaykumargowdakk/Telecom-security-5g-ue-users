#!/usr/bin/env bash
if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run with sudo: sudo ./teardown_ue.sh"
    exit 1
fi

echo "[+] Terminating UERANSIM UE and gNodeB..."
killall -9 -q nr-ue nr-gnb 2>/dev/null || true

echo "[+] Tearing down uesimtun0 interface..."
ip link delete uesimtun0 2>/dev/null || true

echo "[+] Removing static route to 10.0.0.0/24..."
ip route del 10.0.0.0/24 2>/dev/null || true

echo "[SUCCESS] UE and gNodeB torn down cleanly."
