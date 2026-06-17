# 08 Â· Verification

[â† Fedora guest setup](07-fedora-guest-setup.md) Â· [Reversal â†’](09-reversal.md)

This chapter is a single-purpose checklist: prove that DDA actually works
end-to-end. It's also useful as a sanity check after any future change to
the host, BIOS, or VM.

The script
[`scripts/guide/05-health-check.ps1`](../scripts/guide/05-health-check.ps1) automates
most of these.

## 8.1 Host-side checks

```powershell
# 1. Hyper-V is up and IOV is supported
Get-VMHost | Select-Object IovSupport, IovSupportReasons
# Expected: IovSupport: True, IovSupportReasons: (empty)

# 2. Hypervisor IOMMU policy is on
bcdedit /enum "{current}" | Select-String 'hypervisor'
# Expected lines include:
#   hypervisorlaunchtype    Auto
#   hypervisorschedulertype Classic
#   hypervisoriommupolicy   Enable
# vsmlaunchtype            Off

# 3. VBS is off (the LsaIso process is the truest indicator)
"LsaIso.exe running: $([bool](Get-Process -Name LsaIso -ErrorAction SilentlyContinue))"
# Expected: False

# 4. ACS for the GPU is populated
$gpuId = (Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -like 'PCI\VEN_10DE*' -and $_.Class -eq 'Display'
} | Select-Object -First 1).InstanceId
if ($gpuId) {
    "GPU ACS: $((Get-PnpDeviceProperty -InstanceId $gpuId -KeyName 'DEVPKEY_PciDevice_AcsCompatibleUpHierarchy').Data)"
} else {
    "(GPU not present on host â€” likely dismounted, which is correct if you've already attached it)"
}

# 5. VM exists with DDA-compatible settings
$vm = Get-VM -Name Fedora
$vm | Format-List Name, State, ProcessorCount, MemoryStartup, DynamicMemoryEnabled, `
                  AutomaticStopAction, CheckpointType, LowMemoryMappedIoSpace, HighMemoryMappedIoSpace
# Expected: DynamicMemoryEnabled: False, CheckpointType: Disabled, AutomaticStopAction: TurnOff (or ShutDown)

# 6. GPU is assigned to the VM
Get-VMAssignableDevice -VMName Fedora | Format-Table LocationPath, InstanceID -AutoSize
# Expected: two rows (GPU and HDMI audio), both with PCIP\... instance IDs

# 7. VM is running
"VM State: $((Get-VM -Name Fedora).State)"
# Expected: Running
```

## 8.2 Guest-side checks

SSH into the VM (`ssh aseem@<vm-ip>`) and run:

```bash
# 1. Distro and kernel
uname -r
grep PRETTY /etc/os-release
# Expected: kernel 7.0+ (or whatever Fedora 44 ships) and "Fedora Linux 44 (Workstation Edition)"

# 2. The GPU is visible
lspci -nn | grep -iE 'nvidia|10de'
# Expected:
#   xxxx:00:00.0 VGA compatible controller: NVIDIA Corporation GP102 [GeForce GTX 1080 Ti]
#   yyyy:00:00.0 Audio device: NVIDIA Corporation GP102 HDMI Audio Controller

# 3. The proprietary nvidia driver is bound to the GPU
lspci -nnk -d 10de:1b06 | tail -3
# Expected: "Kernel driver in use: nvidia"

# 4. nouveau is NOT loaded
lsmod | grep -iE 'nvidia|nouveau'
# Expected: only nvidia* modules listed

# 5. nvidia-smi works
nvidia-smi
# Expected: full output with model, VRAM, driver version, CUDA version

# 6. CUDA runtime library present
ls /usr/lib64/libcuda* 2>/dev/null
# Expected: libcuda.so, libcuda.so.1, libcuda.so.580.X

# 7. dmesg shows clean PCI passthrough init (no errors)
sudo dmesg | grep -iE 'hv_pci|nvidia|NVRM' | head -20
# Expected: hv_pci probe success, nvidia driver load, no NVRM errors
```

## 8.3 The minimum-viable-success criterion

If the following one-liner shows your GPU's model name and VRAM, **you're
done with the core recipe**:

```bash
$ ssh aseem@<vm-ip> 'nvidia-smi --query-gpu=name,driver_version,memory.total,memory.free --format=csv'
name, driver_version, memory.total [MiB], memory.free [MiB]
NVIDIA GeForce GTX 1080 Ti, 580.159.04, 11264 MiB, 11261 MiB
```

The next chapters cover [reversal](09-reversal.md) (returning the GPU to
the host) and [troubleshooting](troubleshooting.md) (the failure modes we
hit during development).

## 8.4 Optional: CUDA "real" test

To prove the GPU isn't just *visible* but also *usable for compute*, run
a CUDA workload. The simplest path is the official CUDA samples (`vectorAdd`),
or a one-liner via Python with PyTorch in a container â€” which fits nicely
with the [Docker setup we do next](#).

Quick PyTorch test (after [Docker + NVIDIA Container Toolkit](#) is set up):

```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
# Should print the same nvidia-smi output as on the host, proving the
# device is accessible inside containers too.
```

If you don't have Docker installed yet, just compile and run a tiny CUDA
program directly. `nvidia-smi` proving the device is alive is enough for
this chapter.

[â† Fedora guest setup](07-fedora-guest-setup.md) Â· [Reversal â†’](09-reversal.md)
