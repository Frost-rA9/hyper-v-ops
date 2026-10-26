# hyper-v-ops

Scripts that build and operate a Hyper-V virtual machine for remote game streaming. The VM uses GPU partitioning (GPU-PV), a virtual display driver, and a Sunshine server. The client is Moonlight.

An agent that operates this repository starts at `AGENTS.md`, which carries the ordered steps and the completion condition for each step.

## Layout

| Path | Purpose |
|---|---|
| `scripts/worker/worker.ps1` | Elevated worker. Runs admin tasks from a file queue after one UAC prompt |
| `scripts/hyperv/01-enable-hyperv.ps1` | Enable the Hyper-V features |
| `scripts/hyperv/02-network.ps1` | Internal switch, host address, NAT rule |
| `scripts/hyperv/03-create-vm.ps1` | Create the Generation 2 VM |
| `scripts/hyperv/04-build-media.ps1` | Rebuild install media with the answer file |
| `scripts/hyperv/05-install-guest.ps1` | Start the VM and wait for the unattended install |
| `scripts/hyperv/06-snapshot.ps1` | Snapshot with the GPU partition adapter detached |
| `scripts/hyperv/07-connect.ps1` | VMConnect or PowerShell Direct |
| `scripts/gpu-pv/01-host-partition.ps1` | Assign the GPU partition on the host |
| `scripts/gpu-pv/02-guest-driver.ps1` | Copy the display driver inside the guest |
| `scripts/files/push.ps1` | Copy host files into the guest, with SHA256 check |
| `scripts/tools/analyze-shot.ps1` | Measure colour error from a screenshot |
| `reference/calib-reference.png` | Calibration image: 16 grey steps, 8 colour patches |
| `media/autounattend.xml` | Answer file for the unattended install |
| `docs/color-fix.md` | FP16 capture colour fault: symptoms, measurements, root cause |

## Running the scripts

All scripts need an elevated session. Each one lists its parameters in a `param` block. A new host supplies values at call time instead of editing code.

For a session with many steps, start the worker once and send tasks to it. UAC changes the token of a new process only. An elevated process that stays open is therefore the only way to avoid one prompt per command.

1. Start `scripts/worker/worker.ps1` elevated.
2. Write each task as a `.ps1` file into the task directory.
3. Read the result from the output directory.

The worker header documents the queue protocol and the timeout directive.

## Constraints

- **Warning: the answer file creates an administrator with no password.** It also
  clears `LimitBlankPasswordUse`, which lets that account log on over the
  network. PowerShell Direct needs the setting. Use the file for a local test VM
  only. Do not reuse it on a host with a bridged adapter, remote desktop, or a
  route from the internet.
- **Warning: the worker runs any script in its jobs folder as administrator.** Any
  account that can write to that folder can run code with the elevated token.
  Use the worker on a single-user machine.
- **GPU-PV is not a supported configuration.** The vendor supports GPU partitioning on data-centre products only. The guest needs the host driver files copied in, and a host driver update needs the copy repeated.
- **A snapshot needs the adapter detached.** Hyper-V refuses the operation while GPU partitions are assigned to the VM. `scripts/hyperv/06-snapshot.ps1` detaches the adapter first.
- **Builds before the FP16 fix produce a pale image on FP16 captures.** See `docs/color-fix.md`.
- **The virtual display driver ignores the mode list in its settings file.** Set the frame rate on the client instead.
