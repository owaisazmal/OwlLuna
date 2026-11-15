#!/usr/bin/env python3
# Usage: boot-simulator.py ipad|duo|iphone [<iOS version>]. Boots that device on the newest iOS runtime that has it and sets SIMULATOR_UDID.
# The model is looked for on every runtime before anything stands in for it: a newer runtime without a Duo doesn't win.

import json
import os
import subprocess
import sys

DEVICES = {
    "ipad": ("iPad Pro 11-inch", lambda name: name.startswith("iPad Pro 11"), lambda name: name.startswith("iPad")),
    "duo": ("iPhone Duo", lambda name: name == "iPhone Duo", lambda name: name.startswith("iPhone")),
    "iphone": ("iPhone 17", lambda name: name == "iPhone 17",
               lambda name: name.startswith("iPhone") and name != "iPhone Duo"),
}


def simctl(*arguments):
    return subprocess.run(["xcrun", "simctl", *arguments], stdout=subprocess.PIPE, text=True, check=True).stdout


def version(runtime):
    return [int(part) for part in runtime["version"].split(".")]


def find(runtimes, devices, wanted):
    for runtime in runtimes:
        existing = [device for device in devices.get(runtime["identifier"], []) if wanted(device["name"])]
        models = [model for model in runtime["supportedDeviceTypes"] if wanted(model["name"])]
        if existing or models:
            return runtime, existing, models
    return None


def main():
    label, model, stand_in = DEVICES[sys.argv[1]]
    every = [runtime for runtime in json.loads(simctl("list", "runtimes", "available", "--json"))["runtimes"]
             if runtime["platform"] == "iOS"]
    names = ", ".join(runtime["identifier"] for runtime in every) or "none"
    # A version such as 18 or 18.6 keeps to the runtimes it names.
    ios = [int(part) for part in sys.argv[2].split(".")] if len(sys.argv) > 2 else []
    what = f"iOS {sys.argv[2]} runtime" if ios else "iOS runtime"
    runtimes = [runtime for runtime in every if version(runtime)[:len(ios)] == ios]
    if ios and not runtimes:
        print(f"::error::This runner has no {what} ({names}).", flush=True)
        return 1
    runtimes.sort(key=version, reverse=True)
    devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]

    found = find(runtimes, devices, model) or find(runtimes, devices, stand_in)
    if not found:
        print(f"::error::No {what} on this runner has an {label} or a device like it ({names}).", flush=True)
        return 1
    runtime, existing, models = found
    if existing:
        udid, name = existing[0]["udid"], existing[0]["name"]
    else:
        name = models[0]["name"]
        udid = simctl("create", f"CI {name}", models[0]["identifier"], runtime["identifier"]).strip()

    if not model(name):
        print(f"::notice title=Stand-in device::No runtime has an {label}, so this job uses {name}.", flush=True)
    elif version(runtime) < version(runtimes[0]):
        print(f"::notice title=Older iOS runtime::iOS {runtimes[0]['version']} has no {label}, "
              f"so this job uses iOS {runtime['version']}.", flush=True)
    print(f"Booting {name} on {runtime['identifier']}", flush=True)
    subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
    with open(os.environ["GITHUB_ENV"], "a") as env:
        print(f"SIMULATOR_UDID={udid}", file=env)
    return 0


if __name__ == "__main__":
    sys.exit(main())
