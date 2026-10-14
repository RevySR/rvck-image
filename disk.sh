# SPDX-License-Identifier: GPL-2.0
# Byte offsets stay the same for 512-byte and 4K logical sectors.
configure_disk_layout() {
    case $storage in
        generic|emmc|nvme) sector_size=${sector_size:-512};;
        ufs) sector_size=${sector_size:-4096};;
        *) die "storage must be generic, emmc, nvme or ufs";;
    esac
    case $sector_size in
        512|4096) ;;
        *) die "sector size must be 512 or 4096 bytes";;
    esac
    esp_start_mib=1 esp_mib=512 root_start_mib=513
    root_mib=$((size * 1024 - root_start_mib - 1))
}

create_esp() {
    # One 4K sector per cluster keeps this 512 MiB volume valid FAT32.
    local -a cluster_options=()
    truncate -s "${esp_mib}M" "$work/esp.img"
    [[ $sector_size != 4096 ]] || cluster_options=(-s 1)
    mkfs.vfat -F 32 -S "$sector_size" "${cluster_options[@]}" \
        -h "$((esp_start_mib * 1024 * 1024 / sector_size))" \
        -n "${label^^}" "$work/esp.img"
}

create_grubenv() {
    # grub2-editenv in some distributions probes the backing block device,
    # which does not exist for our staging directory. Write the standard
    # empty environment block directly; mkfs.ext4 will populate it later.
    python3 - "$root$grub_dir/grubenv" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'# GRUB Environment Block\n'.ljust(1024, b'#'))
PY
}

create_root_partition() {
    truncate -s "${root_mib}M" "$work/root.img"
    mkfs.ext4 -F -b 4096 -L "$distro-root" -U "$root_uuid" \
        -O '^metadata_csum_seed,^orphan_file' -d "$root" "$work/root.img"
}

assemble_disk() {
    local sectors_per_mib=$((1024 * 1024 / sector_size))
    truncate -s "${size}G" "$work/disk.img"
    # A script sector-size header alone does not set the image sector size.
    sfdisk --sector-size "$sector_size" "$work/disk.img" <<EOF
label: gpt
unit: sectors
sector-size: $sector_size

start=$((esp_start_mib * sectors_per_mib)), size=$((esp_mib * sectors_per_mib)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
start=$((root_start_mib * sectors_per_mib)), size=$((root_mib * sectors_per_mib)), type=$ROOT_TYPE, name="rootfs"
EOF
    dd if="$work/esp.img" of="$work/disk.img" bs=1M \
        seek="$esp_start_mib" conv=notrunc,sparse status=none
    dd if="$work/root.img" of="$work/disk.img" bs=1M \
        seek="$root_start_mib" conv=notrunc,sparse status=none
}
