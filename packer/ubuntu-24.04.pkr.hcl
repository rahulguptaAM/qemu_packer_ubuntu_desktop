packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ---------------------------------------------------------------------------
# Applied timeclock golden image — Ubuntu Server 24.04 for Geekland GKIND101PC
#
# Hardware (confirmed on device):
#   Intel Celeron J6412 (Elkhart Lake), UEFI-only, Secure Boot enabled
#   128 GB SATA SSD -> /dev/sda, root on partition 2
#   Touchscreen 0eef:c002, card reader 0c27:3bfa — both mainline
#
# The app renders straight to /dev/dri via the video/render groups.
# No X, no display manager, no desktop. Server base is correct here.
# ---------------------------------------------------------------------------

variable "image_name" {
  type    = string
  default = "applied-timeclock-ubuntu-24.04-server"
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "none" # set to sha256:... once the release is pinned
}

variable "disk_size" {
  type    = string
  default = "6G"
  # Server + app stack is ~4 GB. Grows to the device's 128 GB on first boot,
  # so this only needs to be big enough to build in.
}

variable "output_dir" {
  type    = string
  default = "output"
}

variable "build_password" {
  type      = string
  default   = "packer-build-2026"
  sensitive = true
  # Must match the hash in http/user-data. Rotate before shipping.
}

variable "efi_code" {
  type    = string
  default = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}

variable "efi_vars" {
  type    = string
  default = "/usr/share/OVMF/OVMF_VARS_4M.fd"
}

source "qemu" "timeclock" {
  vm_name = var.image_name

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  format           = "qcow2" # converted to raw in CI; qcow2 builds faster
  disk_compression = true
  output_directory = "${var.output_dir}/${var.image_name}"
  disk_size        = var.disk_size

  # UEFI. The target device is UEFI-only, so build the same way.
  efi_boot          = true
  efi_firmware_code = var.efi_code
  efi_firmware_vars = var.efi_vars

  # Deliberately unlike a VM: q35 + AHCI + e1000 resembles the real board.
  machine_type   = "q35"
  disk_interface = "ide" # AHCI on q35, matching the device's SATA SSD
  net_device     = "e1000"
  accelerator    = "kvm"
  cpus           = 2
  memory         = 4096
  headless       = true

  # Packer builds a small ISO labelled 'cidata' from these two files.
  # Subiquity reads the autoinstall config from it.
  cd_files = ["./packer/http/user-data", "./packer/http/meta-data"]
  cd_label = "cidata"

  # Interrupt GRUB and add the autoinstall flag, otherwise the installer
  # stops to confirm before wiping the disk.
  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  communicator     = "ssh"
  ssh_username     = "packer"
  ssh_password     = var.build_password
  ssh_timeout      = "45m"
  shutdown_command = "sudo shutdown -P now"

  vnc_bind_address = "127.0.0.1"
}

build {
  sources = ["source.qemu.timeclock"]

  provisioner "shell" {
    inline = [
      "echo 'waiting for cloud-init...'",
      "cloud-init status --wait || true",
    ]
  }

  provisioner "shell" {
    script          = "scripts/10-base.sh"
    execute_command = "sudo -E bash -eux '{{ .Path }}'"
  }

  # ALWAYS LAST. Strips per-device identity.
  provisioner "shell" {
    script          = "scripts/90-cleanup.sh"
    execute_command = "sudo -E bash -eux '{{ .Path }}'"
  }
}
