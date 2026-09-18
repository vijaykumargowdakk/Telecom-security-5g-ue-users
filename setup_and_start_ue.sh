#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    5G MULTI-PARTICIPANT UE / gNodeB DYNAMIC SETUP"
echo "=================================================="

if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run this script with sudo: sudo ./setup_and_start_ue.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Install prerequisites if missing
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

# 3. Prompt for Participant Number
echo ""
echo "--------------------------------------------------"
read -p "[?] Enter Participant Number (1, 2, 3, etc.) [Default: 1]: " PARTICIPANT_NUM
PARTICIPANT_NUM="${PARTICIPANT_NUM:-1}"

# Calculate unique 3GPP IDs
FORMATTED_NUM=$(printf "%010d" "$PARTICIPANT_NUM")
SUPI="imsi-208930000000001"
if [ "$PARTICIPANT_NUM" -gt 1 ]; then
    SUPI=$(printf "imsi-20893%010d" "$PARTICIPANT_NUM")
fi

IMEI_BASE="35693803564380"
IMEI="${IMEI_BASE}${PARTICIPANT_NUM}"
NCI=$(printf "0x%09x0" "$PARTICIPANT_NUM")

echo "[+] Assigned SUPI/IMSI: $SUPI"
echo "[+] Assigned gNodeB NCI: $NCI"
echo "[+] Assigned IMEI:       $IMEI"
echo "--------------------------------------------------"

# 4. If Participant > 1, prompt to register subscriber in Core Webconsole
if [ "$PARTICIPANT_NUM" -gt 1 ]; then
    echo ""
    echo "****************************************************************"
    echo " [!] ATTENTION: SUBSCRIBER MUST BE PROVISIONED ON 5G CORE"
    echo " Before starting the UE, verify this subscriber exists in the"
    echo " free5GC Webconsole (http://<CORE_IP>:5000):"
    echo "   - PLMN ID:             208 / 93"
    echo "   - IMSI:                ${SUPI#imsi-}"
    echo "   - Key:                 8baf473f2f8fd09487cccbd7097c6862"
    echo "   - OP / OPC:            OP"
    echo "   - OP Value:            8e27b6af0e692e750f32667a3b14605d"
    echo "   - S-NSSAI (Slice):     SST: 1, SD: 010203"
    echo "   - Data Network (DNN):  internet"
    echo "****************************************************************"
    read -p "[?] Press [Enter] once subscriber is provisioned in Webconsole to continue..."
fi

# 5. Interface Detection
AVAILABLE_INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo\|dummy\|docker\|tun"))
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
echo ""
echo "[*] Detected network interfaces: ${AVAILABLE_INTERFACES[*]}"
read -p "[?] Enter participant physical/overlay interface [Default: $DEFAULT_IF]: " INPUT_IF
PARTICIPANT_IF="${INPUT_IF:-$DEFAULT_IF}"

PARTICIPANT_IP=$(ip -4 addr show dev "$PARTICIPANT_IF" | grep -m1 inet | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$PARTICIPANT_IP" ]; then
    echo "[-] Error: No IPv4 address found on $PARTICIPANT_IF. Connect to Wi-Fi/Tailscale first."
    exit 1
fi
echo "[+] Detected Participant Local IP: $PARTICIPANT_IP"

# 6. Core Server IP Prompt
read -p "[?] Enter the free5GC Core Server IP: " CORE_SERVER_IP
if [ -z "$CORE_SERVER_IP" ]; then
    echo "[-] Core Server IP cannot be empty."
    exit 1
fi

# 7. Static Routing to 10.0.0.0/24 SBI network (Handles Point-to-Point and Broadcast LAN)
if [ "$PARTICIPANT_IF" = "tailscale0" ]; then
    echo "[+] Point-to-Point device detected (tailscale0). Adding device route to 10.0.0.0/24..."
    ip route replace 10.0.0.0/24 dev tailscale0
else
    echo "[+] Setting static route: 10.0.0.0/24 via $CORE_SERVER_IP on $PARTICIPANT_IF..."
    ip route replace 10.0.0.0/24 via "$CORE_SERVER_IP" dev "$PARTICIPANT_IF"
fi

echo "[*] Testing AMF SBI reachability at 10.0.0.18..."
if ping -c 2 -W 2 10.0.0.18 >/dev/null 2>&1; then
    echo "[+] Reachability verified: Core SBI responds."
else
    echo "[!] Warning: Cannot ping 10.0.0.18. Check network path to $CORE_SERVER_IP."
fi

# 8. Dynamically generate config/free5gc-gnb.yaml
mkdir -p "$SCRIPT_DIR/config"
cat << GNB_EOF > "$SCRIPT_DIR/config/free5gc-gnb.yaml"
mcc: '208'          # Mobile Country Code value
mnc: '93'           # Mobile Network Code value (2 or 3 digits)

nci: '$NCI'  # NR Cell Identity (36-bit)
idLength: 32        # NR gNB ID length in bits [22...32]
tac: 1              # Tracking Area Code

linkIp: $PARTICIPANT_IP   # gNB's local IP address for Radio Link Simulation
ngapIp: $PARTICIPANT_IP   # gNB's local IP address for N2 Interface
gtpIp: $PARTICIPANT_IP    # gNB's local IP address for N3 Interface

# List of AMF address information
amfConfigs:
  - address: $CORE_SERVER_IP
    port: 38412

# List of supported S-NSSAIs by this gNB
slices:
  - sst: 0x1
    sd: 0x010203

# Indicates whether or not SCTP stream number errors should be ignored.
ignoreStreamIds: true

# Cell access type
cellAccessType: nr
GNB_EOF
echo "[+] Generated config/free5gc-gnb.yaml with Cell Identity: $NCI."

# 9. Dynamically generate config/free5gc-ue.yaml
cat << UE_EOF > "$SCRIPT_DIR/config/free5gc-ue.yaml"
# IMSI number of the UE. IMSI = [MCC|MNC|MSISDN] (In total 15 digits)
supi: '$SUPI'
# Mobile Country Code value of HPLMN
mcc: '208'
# Mobile Network Code value of HPLMN (2 or 3 digits)
mnc: '93'
# SUCI Protection Scheme : 0 for Null-scheme, 1 for Profile A and 2 for Profile B
protectionScheme: 0
# Home Network Public Key for protecting with SUCI Profile A
homeNetworkPublicKey: '5a8d38864820197c3394b92613b20b91633cbd897119273bf8e4a6f4eec0a650'
# Home Network Public Key ID for protecting with SUCI Profile A
homeNetworkPublicKeyId: 1
# Routing Indicator
routingIndicator: '0000'

# Permanent subscription key
key: '8baf473f2f8fd09487cccbd7097c6862'
# Operator code (OP or OPC) of the UE
op: '8e27b6af0e692e750f32667a3b14605d'
# This value specifies the OP type and it can be either 'OP' or 'OPC'
opType: 'OP'
# Authentication Management Field (AMF) value
amf: '8000'
# IMEI number of the device. It is used if no SUPI is provided
imei: '$IMEI'
# IMEISV number of the device. It is used if no SUPI and IMEI is provided
imeiSv: '${IMEI}1'

# Network mask used for the UE's TUN interface to define the subnet size
tunNetmask: '255.255.255.0'

# Create the UE TUN interface inside a dedicated Linux network namespace.
useNamespace: false

# Optional prefix used when deriving the namespace name.
nsNamePrefix: 'ueransim'

# List of gNB IP addresses for Radio Link Simulation
gnbSearchList:
  - $PARTICIPANT_IP

# UAC Access Identities Configuration
uacAic:
  mps: false
  mcs: false

# UAC Access Control Class
uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

# Initial PDU sessions to be established
sessions:
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 0x01
      sd: 0x010203

# Configured NSSAI for this UE by HPLMN
configured-nssai:
  - sst: 0x01
    sd: 0x010203

# Default Configured NSSAI for this UE
default-nssai:
  - sst: 1
    sd: 0x010203

# Supported integrity algorithms by this UE
integrity:
  IA1: true
  IA2: true
  IA3: true

# Supported encryption algorithms by this UE
ciphering:
  EA1: true
  EA2: true
  EA3: true

# Integrity protection maximum data rate for user plane
integrityMaxRate:
  uplink: 'full'
  downlink: 'full'
UE_EOF
echo "[+] Generated config/free5gc-ue.yaml for subscriber $SUPI."

# 10. Start gNodeB and UE
echo "[+] Cleaning up previous UERANSIM processes..."
killall -9 -q nr-ue nr-gnb 2>/dev/null || true
sleep 1

echo "[+] Starting gNodeB in background..."
cd "$SCRIPT_DIR"
nohup ./build/nr-gnb -c config/free5gc-gnb.yaml > gnb.log 2>&1 &
GNB_PID=$!
echo "[+] gNodeB started (PID: $GNB_PID). Waiting for SCTP setup..."
sleep 3

if ! grep -q "NG Setup procedure is successful" gnb.log 2>/dev/null; then
    echo "[!] Checking gNodeB connection log:"
    tail -n 5 gnb.log
fi

echo "[+] Starting UE in background..."
nohup ./build/nr-ue -c config/free5gc-ue.yaml > ue.log 2>&1 &
UE_PID=$!
echo "[+] UE started (PID: $UE_PID). Waiting for PDU session tunnel..."

# Wait up to 15s for uesimtun0
COUNT=0
while ! ip addr show dev uesimtun0 >/dev/null 2>&1; do
    sleep 1
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge 15 ]; then
        echo "[-] Timeout waiting for uesimtun0. Inspect ue.log and gnb.log."
        exit 1
    fi
done

# 11. Handle Tailscale MTU Clamping
if [ "$PARTICIPANT_IF" = "tailscale0" ]; then
    echo "[+] Tailscale overlay detected. Clamping uesimtun0 MTU to 1200 bytes..."
    ip link set dev uesimtun0 mtu 1200
fi

TUN_IP=$(ip -4 addr show dev uesimtun0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
echo "=================================================="
echo " [SUCCESS] 5G TUNNEL ESTABLISHED: uesimtun0 ($TUN_IP)"
echo " Participant: $PARTICIPANT_NUM ($SUPI)"
echo " Testing ping to 8.8.8.8..."
ping -c 3 -I uesimtun0 8.8.8.8 || true
echo "=================================================="
