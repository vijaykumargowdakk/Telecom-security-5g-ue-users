#!/usr/bin/env bash
set -e

echo "=================================================="
echo "       5G UE / gNodeB DYNAMIC PARTICIPANT SETUP   "
echo "=================================================="

if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run this script with sudo: sudo ./setup_and_start_ue.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Install prerequisites if needed
if ! command -v cmake >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "[+] Installing compilation dependencies and tools..."
    apt-get update -qq && apt-get install -y -qq make gcc g++ libsctp-dev lksctp-tools iproute2 cmake git jq curl
fi

# 2. Build UERANSIM if not already compiled
if [ ! -f "$SCRIPT_DIR/build/nr-gnb" ] || [ ! -f "$SCRIPT_DIR/build/nr-ue" ]; then
    echo "[+] Compiling UERANSIM binaries..."
    cd "$SCRIPT_DIR"
    make -j$(nproc)
fi

# 3. Detect participant laptop's local IP and network interface
AVAILABLE_INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo\|dummy\|docker\|tun"))
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
echo "[*] Detected network interfaces: ${AVAILABLE_INTERFACES[*]}"
read -p "[?] Enter participant physical interface [Default: $DEFAULT_IF]: " INPUT_IF
PARTICIPANT_IF="${INPUT_IF:-$DEFAULT_IF}"

PARTICIPANT_IP=$(ip -4 addr show dev "$PARTICIPANT_IF" | grep -m1 inet | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$PARTICIPANT_IP" ]; then
    echo "[-] Error: No IPv4 address found on $PARTICIPANT_IF."
    exit 1
fi
echo "[+] Detected Participant Local IP: $PARTICIPANT_IP"

# 4. Prompt for Core Server IP
read -p "[?] Enter the free5GC Core Server IP: " CORE_SERVER_IP
if [ -z "$CORE_SERVER_IP" ]; then
    echo "[-] Core Server IP cannot be empty."
    exit 1
fi

# 5. Add static route to 5G Core SBI dummy network (10.0.0.0/24)
echo "[+] Setting static route: 10.0.0.0/24 via $CORE_SERVER_IP..."
ip route replace 10.0.0.0/24 via "$CORE_SERVER_IP"

echo "[*] Verifying AMF SBI reachability at 10.0.0.18..."
if ping -c 2 -W 2 10.0.0.18 >/dev/null 2>&1; then
    echo "[+] Reachability verified: Core SBI responds."
else
    echo "[!] Warning: Cannot ping 10.0.0.18. Check Ethernet/Wi-Fi connection to $CORE_SERVER_IP."
fi

# 6. Dynamically generate config/free5gc-gnb.yaml
mkdir -p "$SCRIPT_DIR/config"
cat << GNB_EOF > "$SCRIPT_DIR/config/free5gc-gnb.yaml"
mcc: '208'
mnc: '93'
nci: '0x000000010'
idLength: 32
tac: 1

linkIp: $PARTICIPANT_IP
ngapIp: $PARTICIPANT_IP
gtpIp: $PARTICIPANT_IP

amfConfigs:
  - address: $CORE_SERVER_IP
    port: 38412

slices:
  - sst: 1
    sd: 0x010203

ignoreStreamIds: true
GNB_EOF
echo "[+] Generated config/free5gc-gnb.yaml (targeting AMF $CORE_SERVER_IP:38412)."

# 7. Dynamically generate config/free5gc-ue.yaml
cat << UE_EOF > "$SCRIPT_DIR/config/free5gc-ue.yaml"
supi: 'imsi-208930000000001'
mcc: '208'
mnc: '93'
key: '8baf473f2f8fd09487cccbd7097c6862'
op: '8e27b6af0e692e750f32667a3b14605d'
opType: 'OP'
amf: '8000'
imei: '356938035643803'
imeiSv: '4370816125816151'

gnbSearchList:
  - $PARTICIPANT_IP

uacAic:
  mps: false
  mcs: false
uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

sessions:
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 1
      sd: 0x010203

configured-nssai:
  - sst: 1
    sd: 0x010203

default-nssai:
  - sst: 1
    sd: 0x010203

integrity:
  IA1: true
  IA2: true
  IA3: true
ciphering:
  EA1: true
  EA2: true
  EA3: true
integrityMaxRate:
  uplink: 'full'
  downlink: 'full'
UE_EOF
echo "[+] Generated config/free5gc-ue.yaml (searching gNodeB at $PARTICIPANT_IP)."

# 8. Start gNodeB and UE
echo "[+] Terminating old UERANSIM processes..."
killall -9 -q nr-ue nr-gnb 2>/dev/null || true
sleep 1

echo "[+] Starting gNodeB in background..."
cd "$SCRIPT_DIR"
nohup ./build/nr-gnb -c config/free5gc-gnb.yaml > gnb.log 2>&1 &
GNB_PID=$!
echo "[+] gNodeB PID: $GNB_PID. Waiting for SCTP association..."
sleep 3

if ! grep -q "NG Setup procedure is successful" gnb.log 2>/dev/null; then
    echo "[!] Checking gNodeB connection..."
    tail -n 5 gnb.log
fi

echo "[+] Starting UE in background..."
nohup ./build/nr-ue -c config/free5gc-ue.yaml > ue.log 2>&1 &
UE_PID=$!
echo "[+] UE PID: $UE_PID. Waiting for PDU session tunnel..."

# Wait up to 15s for uesimtun0
COUNT=0
while ! ip addr show dev uesimtun0 >/dev/null 2>&1; do
    sleep 1
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge 15 ]; then
        echo "[-] Timeout waiting for uesimtun0. Inspect gnb.log and ue.log."
        exit 1
    fi
done

TUN_IP=$(ip -4 addr show dev uesimtun0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
echo "=================================================="
echo " [SUCCESS] 5G TUNNEL ESTABLISHED: uesimtun0 ($TUN_IP)"
echo " Testing ping to 8.8.8.8..."
ping -c 3 -I uesimtun0 8.8.8.8 || true
echo "=================================================="
