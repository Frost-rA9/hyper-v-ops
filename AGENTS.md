# AGENTS.md

Entry point for an agent that operates this repository. Read this file before you run a script.

## Operating rules

- Run the scripts in an elevated PowerShell session. They change Hyper-V configuration and guest drivers.
- Run one step. Read the `Done` condition. Continue only when the condition holds.
- Pass every path and name as a parameter. The defaults are neutral values, not values for a specific host.
- Report the `Done` result and the error text. A zero exit code alone does not prove that the step worked.
- Use the worker for a session with two steps or more. See "Worker" below.

## Worker

The worker holds one elevated process open for the whole session. UAC changes the token of a new process only, so a direct call to each script asks for consent again.

1. Start `scripts/worker/worker.ps1` from an elevated PowerShell.
   - `Done`: the worker writes `worker.status.txt` and the file reports `elevated : True`.
2. Write each task as a `<id>.ps1` file into `<repo>\.worker\jobs\`.
   - `Done`: the file is in the folder under the expected name.
3. Read `<repo>\.worker\out\<id>.json` after the run.
   - `Done`: the file exists and its `exit` field is 0.
4. Write `<repo>\.worker\stop.txt` to end the session.
   - `Done`: the worker process exits and removes `worker.lock`.

Add `#TIMEOUT: <seconds>` on the first line of a task that needs more than 900 seconds.

## Steps

### 1. Enable Hyper-V

- Run: `scripts/hyperv/01-enable-hyperv.ps1`
- `Done`: every listed feature reports `Enabled`.
- If not: the script reports a pending restart. Restart the host and repeat this step.

### 2. Create the network

- Run: `scripts/hyperv/02-network.ps1`
- `Done`: the host address reports `Preferred` and the NAT rule reports `Active : True`.
- If not: a rule with the same name already exists. Inspect it with `Get-VMSwitch` or `Get-NetNat`.

### 3. Build the install media

- Run: `scripts/hyperv/04-build-media.ps1 -SourceIso <iso> -AnswerFile media\autounattend.xml -OutIso <out.iso> -PromptlessBoot`
- `Done`: the last line reports `Answer file written: True`.
- If not: the staged copy is incomplete. Check that `setup.exe` and `sources\boot.wim` exist in the source media.

### 4. Create the VM

- Run: `scripts/hyperv/03-create-vm.ps1 -Name <vm> -VhdPath <vhdx path> -SwitchName HvSwitch -IsoPath <out.iso>`
- `Done`: `Get-VM` reports `Off` and `DynamicMemoryEnabled : False`.
- If not: a virtual machine or a switch already uses that name. Choose another name.

### 5. Install the guest

- Run: `scripts/hyperv/05-install-guest.ps1 -Name <vm> -User <account>`
- `Done`: the script prints `Install finished. PowerShell Direct answers.`
- If not: the script prints `No disk write in six minutes`. The media waits for a keypress. Repeat step 3 with `-PromptlessBoot`.

### 6. Assign the GPU partition

- Run: `Stop-VM -Name <vm>`, then `scripts/gpu-pv/01-host-partition.ps1 -Name <vm>`.
- `Done`: `Get-VMGpuPartitionAdapter` reports a partition ID and a value for `CurrentPartitionVRAM`.
- If not: `Start-VM` reports `0x800705AA`. The partition limits reserve more memory than the host allows. Restore the limits in the script.

### 7. Copy the driver

- Run: `scripts/files/push.ps1 -VMName <vm> -SourcePath <driver package> -DestDir <guest path> -VhdPath <vhdx> -User <account>`, then `scripts/gpu-pv/02-guest-driver.ps1 -PackagePath <guest path>`.
- `Done`: `Get-PnpDevice -Class Display` reports `Status OK` for the vendor device, and the script prints no `Code 43`.
- If not: the device still reports `Code 43`. Copy all three locations named in the script header.

### 8. Install the virtual display driver and the server

- Run: the two installers inside the guest.
- `Done`: the server log contains `Treating FP16 SDR capture as gamma-encoded` when the capture format is FP16.
- If not: the log reports `Desktop format [DXGI_FORMAT_R16G16B16A16_FLOAT]` without the gamma line. The build is older than the fix. Read `docs/color-fix.md`.

### 9. Measure the colour path

- Run: set `reference/calib-reference.png` as the guest wallpaper. Take a PNG screenshot of the client window. Run `scripts/tools/analyze-shot.ps1 -Path <png>`.
- `Done`: the script reports a gamma between 0.99 and 1.01, and an error of at most 2 per cell.
- If not: read `docs/color-fix.md` for the measured cases and the configuration check.

## Notes

- A snapshot needs the GPU partition adapter detached. Run `scripts/hyperv/06-snapshot.ps1`. It detaches the adapter, takes the snapshot, and attaches the adapter again.
- The guest account may have no password. PowerShell Direct then needs `LimitBlankPasswordUse = 0` inside the guest. `media/autounattend.xml` sets this value.
- The guest restarts at least once between step 6 and step 8. Wait for PowerShell Direct after each restart before you continue.
