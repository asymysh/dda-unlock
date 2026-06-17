# 03 · BIOS configuration

[← Prerequisites](02-prerequisites.md) · [Windows host setup →](04-windows-host-setup.md)

This chapter walks through the BIOS-level enables. Without these, no
amount of OS configuration will make DDA work — the hypervisor needs the
firmware to expose the right IOMMU and PCIe isolation primitives.

The exact menu paths below are for **ASUS Pro WS X570-ACE**. Names vary
slightly by board vendor and AGESA version; the *concepts* generalize.
After every BIOS section we give a PowerShell command you can run from
Windows to verify the setting took effect.

## 3.1 Required settings (must-have)

Reboot into BIOS (typically `Del` or `F2` at POST), enter Advanced Mode
(`F7` on ASUS), and visit each of the following menus.

### CPU virtualization

| Path | Setting | Value |
|---|---|---|
| Advanced → CPU Configuration | **SVM Mode** (AMD) / **Intel VT-x** | **Enabled** |
| Advanced → CPU Configuration | NX bit / Execute Disable | Enabled (usually default) |

Without SVM, Hyper-V cannot run.

**Verify** (PowerShell):
```powershell
(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled
# Expect: True
```

### IOMMU

| Path | Setting | Value |
|---|---|---|
| Advanced → AMD CBS → NBIO Common Options → IOMMU | **IOMMU** | **Enabled** |
| Advanced → AMD CBS → NBIO Common Options → IOMMU | IVRS IOAPIC Support | Auto |
| Advanced → AMD CBS → NBIO Common Options → IOMMU | IOMMU EFR Enabled | Enabled |

IOMMU is what gives the hypervisor the ability to remap DMA from PCIe
devices into guest VM memory. Without it, DDA cannot work at all.

### ACS (Access Control Services) — the critical one

| Path | Setting | Value |
|---|---|---|
| Advanced → AMD CBS → NBIO Common Options → IOMMU | **ACS Enable** | **Enabled** |

This is the setting that makes consumer AM4 boards fail DDA. ACS lets the
PCIe topology declare to the OS that devices are properly isolated and
can't peer-DMA each other. Hyper-V checks for this when assigning a device
to a VM.

Without it, the GPU's `AcsCompatibleUpHierarchy` property comes back empty
and DDA's safety check fails. With it, the property reads `3`
(SingleHierarchy + Adjacent), which is what we want.

**Verify** (PowerShell, after Windows boots):
```powershell
$gpu = Get-PnpDevice -Class Display -PresentOnly | Where-Object { $_.FriendlyName -like '*NVIDIA*' }
$gpuId = $gpu.InstanceId
(Get-PnpDeviceProperty -InstanceId $gpuId -KeyName 'DEVPKEY_PciDevice_AcsCompatibleUpHierarchy').Data
# Expect: 3   (anything non-empty/non-zero is acceptable; empty = ACS not exposed)
```

### Above 4G Decoding

| Path | Setting | Value |
|---|---|---|
| Advanced → PCI Subsystem Settings | **Above 4G Decoding** | **Enabled** |

Modern GPUs need MMIO windows above the 4 GB boundary. The GTX 1080 Ti
needs ~32 GB of high MMIO room. Without Above 4G enabled, the VM can't
allocate the MMIO and the VPCI port fails to power on.

## 3.2 Recommended settings

### SR-IOV support

| Path | Setting | Value |
|---|---|---|
| Advanced → PCI Subsystem Settings | SR-IOV Support | Enabled |

Not strictly required for DDA (DDA isn't SR-IOV), but enabling it gives
Hyper-V's `IovSupport` more capabilities and helps populate ACS info.

### Re-Size BAR

| Path | Setting | Value |
|---|---|---|
| Advanced → PCI Subsystem Settings | Re-Size BAR Support | Enabled (or Disabled — doesn't matter for Pascal) |

Re-Size BAR only matters for newer GPUs (Ampere and later). For Pascal it's
inert. Leave at whatever default makes the rest of your system happy.

### PCIe ARI Support

| Path | Setting | Value |
|---|---|---|
| Advanced → AMD CBS → NBIO Common Options | PCIe ARI Support | Enabled |

ARI lets PCIe devices expose >8 functions. Enabling it helps populate
`AcsCompatibleUpHierarchy`. **Caveat**: certain older Realtek NICs
(specifically the 8168-family used as BMC LAN on some workstation boards)
fail to enumerate when ARI is enabled. If you have a Realtek BMC NIC and
it disappears after enabling ARI, see
[`reference/realtek-nic-issue.md`](../reference/realtek-nic-issue.md).

## 3.3 Leave these alone

These are commonly suggested in random forum threads but **don't matter**
for DDA:

- **Pre-Boot DMA Protection** — if you find it, disable. Otherwise ignore.
- **AMD SME / TSME** (Secure Memory Encryption) — if enabled, disable; if
  not present, ignore.
- **CSM** (Compatibility Support Module) — should be **Disabled** anyway
  for UEFI-only boot, which is required for Gen 2 Hyper-V VMs.
- **Secure Boot** (in BIOS) — irrelevant to DDA. Host Secure Boot does not
  affect Hyper-V's DDA capability.

## 3.4 Save and reboot

Save (F10 on ASUS) and let Windows boot. Then verify all four critical
settings landed:

```powershell
# All four must look good:
"VirtFw enabled : $((Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled)"

Get-VMHost | Format-List IovSupport, IovSupportReasons
# IovSupport should be True (or False with reasons that don't include "ACS")

$gpuId = (Get-PnpDevice -Class Display -PresentOnly | Where-Object { $_.FriendlyName -like '*NVIDIA*' }).InstanceId
"ACS : $((Get-PnpDeviceProperty -InstanceId $gpuId -KeyName 'DEVPKEY_PciDevice_AcsCompatibleUpHierarchy').Data)"
# ACS should be a non-empty number (3 is typical)

(Get-PnpDeviceProperty -InstanceId $gpuId -KeyName 'DEVPKEY_PciDevice_RequiresReservedMemoryRegion').Data
# Should be False
```

If any of these look wrong, fix the BIOS setting before continuing.

## 3.5 Common BIOS pitfalls

| Symptom | Likely cause | Fix |
|---|---|---|
| `IovSupport: False`, reason mentions "PCI Express hardware does not support ACS" | ACS not enabled in BIOS | Enable ACS as above |
| `IovSupport: False`, reason mentions "Hypervisor is not running" | SVM/VT-x disabled | Re-enable SVM in BIOS |
| `AcsCompatibleUpHierarchy` is empty | ACS not exposed by this board | Try a BIOS update; if no joy, your board is incompatible |
| Realtek/Intel NIC disappears after BIOS changes | ARI breakage | Disable PCIe ARI Support |
| Windows won't boot after BIOS save | Most often a power loss during BIOS flash, or accidentally toggling CPU multiplier | CMOS reset jumper |

Once all four critical settings verify correctly, you can move on to the
[Windows host setup](04-windows-host-setup.md), which is where the
**ProductType flip** — the actual DDA unlock — happens.

[← Prerequisites](02-prerequisites.md) · [Windows host setup →](04-windows-host-setup.md)
