#!/usr/bin/env python3
"""mock_ilo.py - a tiny fake HPE iLO 6 Redfish service for testing
laptop/bios-profile.ps1 offline. Standard library only.

    python3 tests/redfish-mock/mock_ilo.py PORT [--missing NAME ...]

Behaves like iLO where it matters for the script:
- needs HTTP Basic auth (admin / secret)
- GET  /redfish/v1/Systems/1/Bios/            current attributes + registry name
- GET  .../bios/settings/                      pending attributes
- PATCH .../bios/settings/                     stores pending (applied at "reboot")
- GET  /redfish/v1/Registries/<name>/          -> Location -> attribute registry
- POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/   "reboots":
  pending values are applied, EXCEPT options that are locked by a workload
  profile (PowerRegulator, MinProcIdlePower, ...) unless WorkloadProfile is
  Custom - the same rule HPE documents, so -Verify must catch it.
Attribute names/values follow HPE's iLO 6 v1.62 BIOS resource definitions.
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REG_NAME = "BiosAttributeRegistryA55.v1_2_68"
REG_URI = "/redfish/v1/registrystore/registries/en/biosattributeregistrya55.v1_2_68/"

ENUMS = {
    "WorkloadProfile": ["GeneralPowerEfficientCompute", "GeneralPeakFrequencyCompute",
                        "GeneralThroughputCompute", "Virtualization-PowerEfficient",
                        "Virtualization-MaxPerformance", "LowLatency", "MissionCritical",
                        "TransactionalApplicationProcessing", "HighPerformanceCompute(HPC)",
                        "DecisionSupport", "GraphicProcessing", "I/OThroughput", "Custom"],
    "PowerRegulator": ["StaticHighPerf", "OsControl"],
    "MinProcIdlePower": ["C6", "C1", "NoCStates"],
    "CollabPowerControl": ["Disabled", "Enabled"],
    "ProcAMDBoost": ["Disabled", "Enabled"],
    "DeterminismControl": ["DeterminismCtrlAuto", "DeterminismCtrlManual"],
    "PerformanceDeterminism": ["PerformanceDeterministic", "PowerDeterministic"],
    "PackagePowerLimitControlMode": ["Auto", "Manual"],
    "DataFabricCStateEnable": ["Auto", "ForceEnabled", "Disabled"],
    "InfinityFabricPstate": ["P0", "P1", "P2", "P3", "Auto"],
    "AmdMemPStates": ["Auto", "Disabled"],
    "MaxMemBusFreqMHz": ["Auto", "MaxMemBusFreq4800", "MaxMemBusFreq4400"],
    "NumaMemoryDomainsPerSocket": ["OneMemoryDomainPerSocket", "TwoMemoryDomainsPerSocket",
                                   "FourMemoryDomainsPerSocket", "Auto"],
    "ThermalConfig": ["OptimalCooling", "IncreasedCooling", "MaxCooling", "EnhancedCPUCooling"],
    "Sriov": ["Enabled", "Disabled"],
    "ProcAmdIoVt": ["Enabled", "Disabled"],
    "AmdDmaRemapping": ["Enabled", "Disabled"],
    "ProcSMT": ["Enabled", "Disabled"],
}
INTEGERS = {"PackagePowerLimitValue": (0, 240)}
# factory defaults (GeneralPowerEfficientCompute)
CURRENT = {
    "WorkloadProfile": "GeneralPowerEfficientCompute", "PowerRegulator": "OsControl",
    "MinProcIdlePower": "C6", "CollabPowerControl": "Enabled", "ProcAMDBoost": "Enabled",
    "DeterminismControl": "DeterminismCtrlAuto", "PerformanceDeterminism": "PerformanceDeterministic",
    "PackagePowerLimitControlMode": "Auto", "PackagePowerLimitValue": 0,
    "DataFabricCStateEnable": "Auto", "InfinityFabricPstate": "Auto", "AmdMemPStates": "Auto",
    "MaxMemBusFreqMHz": "Auto", "NumaMemoryDomainsPerSocket": "Auto",
    "ThermalConfig": "OptimalCooling", "Sriov": "Enabled", "ProcAmdIoVt": "Enabled",
    "AmdDmaRemapping": "Enabled", "ProcSMT": "Enabled",
}
# what the HPC profile sets when applied at boot
HPC = {"PowerRegulator": "StaticHighPerf", "MinProcIdlePower": "NoCStates",
       "CollabPowerControl": "Disabled", "DataFabricCStateEnable": "Disabled",
       "InfinityFabricPstate": "P0", "PerformanceDeterminism": "PowerDeterministic"}
LOCKED = {"PowerRegulator", "MinProcIdlePower", "CollabPowerControl"}

PENDING = {}
POWER = {"state": "On", "resets": 0}


def registry(missing):
    attrs = []
    for name, vals in ENUMS.items():
        if name in missing:
            continue
        attrs.append({"AttributeName": name, "Type": "Enumeration", "ReadOnly": False,
                      "Value": [{"ValueName": v, "ValueDisplayName": v} for v in vals]})
    for name, (lo, hi) in INTEGERS.items():
        if name not in missing:
            attrs.append({"AttributeName": name, "Type": "Integer", "ReadOnly": False,
                          "LowerBound": lo, "UpperBound": hi})
    return {"RegistryEntries": {"Attributes": attrs}}


def reboot():
    global PENDING
    profile = PENDING.get("WorkloadProfile", CURRENT["WorkloadProfile"])
    for k, v in PENDING.items():
        if k in LOCKED and profile != "Custom":
            continue          # locked by the workload profile: ignored, like the real BIOS
        CURRENT[k] = v
    if PENDING.get("WorkloadProfile") == "HighPerformanceCompute(HPC)":
        CURRENT.update(HPC)
    PENDING = {}
    POWER["resets"] += 1


class H(BaseHTTPRequestHandler):
    missing = set()

    def log_message(self, *a):
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        want = "Basic " + base64.b64encode(b"admin:secret").decode()
        if self.headers.get("Authorization") != want:
            self.send(401, {"error": {"code": "iLO.0.10.ExtendedInfo",
                                      "message": "Login failed"}})
            return False
        return True

    def path_l(self):
        return self.path.lower().rstrip("/") + "/"

    def do_GET(self):
        if not self.authed():
            return
        p = self.path_l()
        if p == "/redfish/v1/systems/1/bios/":
            self.send(200, {"AttributeRegistry": REG_NAME, "Attributes": CURRENT,
                            "@Redfish.Settings": {"SettingsObject": {
                                "@odata.id": "/redfish/v1/systems/1/bios/settings/"}}})
        elif p == "/redfish/v1/systems/1/bios/settings/":
            self.send(200, {"Attributes": dict(CURRENT, **PENDING)})
        elif p == f"/redfish/v1/registries/{REG_NAME.lower()}/":
            self.send(200, {"Location": [{"Language": "en", "Uri": REG_URI}]})
        elif p == REG_URI:
            self.send(200, registry(self.missing))
        elif p == "/redfish/v1/systems/1/":
            self.send(200, {"PowerState": POWER["state"]})
        elif p == "/mock/state/":
            self.send(200, {"current": CURRENT, "pending": PENDING, "resets": POWER["resets"]})
        else:
            self.send(404, {"error": {"message": "not found " + self.path}})

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def do_PATCH(self):
        if not self.authed():
            return
        if self.path_l() != "/redfish/v1/systems/1/bios/settings/":
            return self.send(405, {"error": {"message": "PATCH not allowed here"}})
        attrs = self.body().get("Attributes", {})
        for k, v in attrs.items():
            if k in INTEGERS:
                lo, hi = INTEGERS[k]
                if not isinstance(v, int) or not lo <= v <= hi:
                    return self.send(400, {"error": {"message": f"bad value for {k}: {v!r}"}})
            elif k not in ENUMS or k in self.missing or v not in ENUMS[k]:
                return self.send(400, {"error": {"message": f"bad attribute {k}={v!r}"}})
        PENDING.update(attrs)
        self.send(200, {"error": {"@Message.ExtendedInfo": [
            {"MessageId": "iLO.2.15.SystemResetRequired"}]}})

    def do_POST(self):
        if not self.authed():
            return
        if self.path_l() == "/redfish/v1/systems/1/actions/computersystem.reset/":
            t = self.body().get("ResetType")
            if t not in ("ForceRestart", "On", "GracefulRestart"):
                return self.send(400, {"error": {"message": f"bad ResetType {t}"}})
            reboot()
            return self.send(200, {"error": {"@Message.ExtendedInfo": [{"MessageId": "Base.1.4.Success"}]}})
        self.send(404, {"error": {"message": "not found"}})


if __name__ == "__main__":
    port = int(sys.argv[1])
    if "--missing" in sys.argv:
        H.missing = set(sys.argv[sys.argv.index("--missing") + 1:])
        # a server that lacks settings runs other firmware: another registry
        # version (iLO names registries by version, so caches never mix)
        REG_NAME = "BiosAttributeRegistryA55.v1_2_60"
        REG_URI = "/redfish/v1/registrystore/registries/en/biosattributeregistrya55.v1_2_60/"
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
