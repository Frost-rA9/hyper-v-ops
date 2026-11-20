# Guest display driver update

## Conclusion

The guest must run the same display driver package as the host. GPU-PV gives the guest one partition of the host GPU, and the guest driver must match the host driver.

A host driver update does not touch the guest. Copy the driver files into the guest again after each host update.

## How to tell that the guest needs an update

Compare the package version on both sides.

Host, the installed package:

- The folder `C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_<hash>` holds the package.
- The line `DriverVer` in `nv_dispi.inf` gives the version of the package.
- The active device reports the same version in `Get-PnpDevice -Class Display`.

Guest, the copied package:

- The folder `C:\Windows\System32\HostDriverStore\FileRepository\nv_dispi.inf_amd64_<hash>` holds the package.
- The line `DriverVer` in `nv_dispi.inf` gives the version of the package.
- `C:\Windows\System32\drivers\nvlddmkm.sys` gives the version of the kernel driver.

The guest `DriverStore\FileRepository` holds no `nv_dispi` folder. The `HostDriverStore` folder is the correct location. Do not read the guest `DriverStore`.

Update the driver in three cases:

- The two `DriverVer` values differ.
- The two folder names differ, which means the packages differ.
- The version of `nvlddmkm.sys` differs from the host package.

When the VM is off, mount the disk read-only and read the file version of `nvlddmkm.sys`. A read-only mount does not change the guest.

## Update the driver while the guest answers

1. Start the VM.
2. Wait until PowerShell Direct answers.
3. Run `scripts/files/push.ps1` with the host package folder as `-SourcePath`. Use the new folder under the guest `HostDriverStore\FileRepository` as `-DestDir`.
4. Run `scripts/gpu-pv/02-guest-driver.ps1` in the guest with the guest folder as `-PackagePath`.
5. Remove each other `nv_dispi.inf_amd64_*` folder from the guest `HostDriverStore\FileRepository`.
6. Restart the guest.

`Done`: `Get-PnpDevice -Class Display` reports `Status OK` for the vendor device. The version of `nvlddmkm.sys` matches the host package.

## Update the driver when the guest does not start

A guest with a driver that does not match the host stops during start-up. PowerShell Direct then gives no answer, and the steps above cannot run. Use the steps below instead.

Two faults give this symptom:

1. The guest driver differs from the host driver.
2. The GPU partition points at a different GPU than the one that holds the driver files. `scripts/gpu-pv/01-host-partition.ps1` documents this fault and names `-GpuMatch` for it.

Check the partition before you touch the disk. Run `Get-VMGpuPartitionAdapter -VMName <vm>`. `InstancePath` must contain the text for the expected GPU, for example `VEN_10DE` for an NVIDIA card.

The host event log reports the fault in `Microsoft-Windows-Hyper-V-Worker-Admin`:

- Event 18590 with `ErrorCode0` 0x3B and `ErrorCode1` 0xC0000005.
- Event 18514 (guest reset) and event 18601 in a loop.

The guest integration services report that the guest does not answer. The counter `Uptime` keeps increasing while the guest does not answer.

### Steps

1. Run `Stop-VM -Name <vm>`. If the guest does not answer, run `Stop-VM -Name <vm> -TurnOff -Force`.
2. Read the disk path with `(Get-VMHardDiskDrive -VMName <vm> | Where-Object ControllerLocation -eq 0).Path`.
3. Run `Mount-VHD -Path <disk>`. Without `-ReadOnly` the mount is read-write.
4. Find the Windows volume and check two files. `Windows\WinSxS\pending.xml` and `Windows\System32\config\PendingRename` must not exist.
5. Copy the host package folder to `Windows\System32\HostDriverStore\FileRepository\<package name>` on the volume.
6. Copy the `nv*.dll` files from the top level of the package to `Windows\System32`.
7. Copy `nvlddmkm.sys` to `Windows\System32\drivers`.
8. Remove each other `nv_dispi.inf_amd64_*` folder from `HostDriverStore\FileRepository`.
9. Run `Dismount-VHD -Path <disk>`.
10. Run `scripts/gpu-pv/01-host-partition.ps1 -Name <vm> -GpuMatch <text>`.
11. Run `Start-VM -Name <vm>`.

If step 4 finds either file, stop there. A servicing operation is incomplete, and a disk that changes during servicing loses the component store. Dismount the disk and report the finding.

`Done`: the guest answers PowerShell Direct. `Get-PnpDevice -Class Display` reports `Status OK` and no `Code 43`. The version of `nvlddmkm.sys` matches the host package. The host event log has no new event 18590.

On the host used for this document, the guest answered between 45 seconds and 160 seconds after the start.

## Take a checkpoint first

Run `scripts/hyperv/06-snapshot.ps1` before the change. The script detaches the GPU partition adapter, takes the checkpoint, and attaches the adapter to the same GPU again. The script name says "snapshot". Hyper-V calls the same object a checkpoint.

A checkpoint adds a disk to the chain, and the VM writes to the new disk. A path from an earlier session points at an older layer of the chain. Read the path with `Get-VMHardDiskDrive` each time. Do not keep a path in a script.

## Files that stay at the old version

The display package holds no `nvcuda.dll` and no `nvcuvid.dll`. Both files stay at an older version in the guest `System32`. They serve CUDA and video decode. They do not drive the display output. Leave them.
