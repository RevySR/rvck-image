# SPDX-License-Identifier: GPL-2.0
# Assemble the selected kernel in staging, independently of the rootfs.
resolve_kernel_rpms() {
    local input package canonical LC_ALL=C
    local -a expanded=() candidates=()
    local -A seen=()
    for input in "${kernel_rpms[@]}"; do
        if [[ -d $input ]]; then
            candidates=()
            for package in "$input"/*.rpm; do
                [[ -f $package ]] && candidates+=("$package")
            done
            ((${#candidates[@]})) || die "no RPM files in directory: $input"
        else
            [[ -f $input ]] || die "kernel RPM does not exist: $input"
            candidates=("$input")
        fi
        for package in "${candidates[@]}"; do
            canonical=$(realpath "$package")
            if [[ ! ${seen[$canonical]+present} ]]; then
                expanded+=("$canonical")
                seen[$canonical]=1
            fi
        done
    done
    kernel_rpms=("${expanded[@]}")
}

prepare_kernel_image() {
    local input=$1 output=$2 description
    local -a unpack
    description=$(LC_ALL=C file -b "$input")
    case $description in
        *'RISC-V boot executable Image'*)
            cp "$input" "$output" || die "cannot copy kernel: $input"
            return 0;;
        *'gzip compressed data'*) unpack=(gzip -dc);;
        *'bzip2 compressed data'*) unpack=(bzip2 -dc);;
        *'XZ compressed data'*) unpack=(xz -dc);;
        *'LZMA compressed data'*) unpack=(lzma -dc);;
        *'LZ4 compressed data'*) unpack=(lz4 -dc);;
        *'lzop compressed data'*) unpack=(lzop -dc);;
        *'Zstandard compressed data'*) unpack=(zstd -dc);;
        *) return 1;;
    esac
    need "${unpack[0]}"
    "${unpack[@]}" -- "$input" > "$output" \
        || die "cannot decompress kernel: $input"
    LC_ALL=C file -b "$output" | grep -q 'RISC-V boot executable Image' \
        || die "decompressed kernel is not a RISC-V Image: $input"
}

install_kernel() {
    local kernel_root module_base built_version candidate name package
    local package_info package_arch
    local -a versions
    kernel_root=$work/kernel
    if [[ -n $kernel_tree ]]; then
        need make
        [[ -f $kernel_tree/.config ]] \
            || die "configure the kernel tree first"
        if [[ $(uname -m) != riscv64 && -z $cross_compile ]]; then
            cross_compile=riscv64-linux-gnu-
        fi
        make -C "$kernel_tree" ARCH=riscv CROSS_COMPILE="$cross_compile" \
            -j"$jobs" Image modules
        built_version=$(make -s --no-print-directory -C "$kernel_tree" \
            ARCH=riscv CROSS_COMPILE="$cross_compile" kernelrelease)
        [[ -z $kver || $kver == "$built_version" ]] \
            || die "kernel version mismatch"
        kver=$built_version
        make -C "$kernel_tree" ARCH=riscv CROSS_COMPILE="$cross_compile" \
            INSTALL_MOD_PATH="$work/kernel" DEPMOD=true modules_install
        mkdir -p "$work/kernel/boot"
        cp "$kernel_tree/.config" "$work/kernel/boot/config-$kver"
        cp "$kernel_tree/System.map" "$work/kernel/boot/System.map-$kver"
        cp "$kernel_tree/arch/riscv/boot/Image" \
            "$work/kernel/boot/vmlinuz-$kver"
    elif [[ -n $kernel_deb ]]; then
        need dpkg-deb
        [[ $(dpkg-deb -f "$kernel_deb" Architecture) == riscv64 ]] \
            || die "kernel .deb is not riscv64"
        dpkg-deb -x "$kernel_deb" "$work/kernel"
    elif ((${#kernel_rpms[@]})); then
        need rpm rpm2cpio cpio
        for package in "${kernel_rpms[@]}"; do
            package_info=$(rpm -qp --qf '%{ARCH} %{SOURCEPACKAGE}' "$package")
            [[ $package_info != *' 1' ]] \
                || die "source RPM cannot supply a kernel: $package"
            package_arch=${package_info%% *}
            [[ $package_arch == riscv64 || $package_arch == noarch ]] \
                || die "kernel RPM is not riscv64 or noarch: $package"
        done
        for package in "${kernel_rpms[@]}"; do
            (cd "$work/kernel"; rpm2cpio "$package" \
                | cpio -idm --quiet --no-absolute-filenames)
        done
    fi
    module_base=$kernel_root/usr/lib/modules
    [[ -d $module_base ]] || module_base=$kernel_root/lib/modules
    [[ -d $module_base ]] || die "matching kernel modules are missing"
    if [[ -z $kver ]]; then
        mapfile -t versions < <(find "$module_base" -mindepth 1 \
            -maxdepth 1 -type d -printf '%f\n')
        ((${#versions[@]} == 1)) \
            || die "select a version with --kernel-version"
        kver=${versions[0]}
    fi
    [[ $kver =~ ^[a-zA-Z0-9._+-]+$ && $kver != . && $kver != .. \
        && -d $module_base/$kver ]] \
        || die "invalid or missing kernel version"
    if [[ -n $kernel_image ]]; then
        [[ -f $kernel_image ]] || die "kernel Image does not exist"
        prepare_kernel_image "$kernel_image" "$work/Image" \
            || die "unsupported kernel image: $kernel_image"
    else
        kernel_image=
        for candidate in "$kernel_root/boot/vmlinuz-$kver" \
            "$kernel_root/boot/vmlinux-$kver" \
            "$kernel_root/boot/Image-$kver" \
            "$module_base/$kver/vmlinuz" "$module_base/$kver/Image"; do
            [[ -f $candidate ]] || continue
            if prepare_kernel_image "$candidate" "$work/Image"; then
                kernel_image=$candidate
                break
            fi
        done
        [[ -n $kernel_image ]] \
            || die "no supported RISC-V Image; use --kernel-image"
    fi
    kernel_image=$work/Image
    [[ $(od -An -tx1 -N2 "$kernel_image" | tr -d ' \n') == 4d5a ]] \
        || die "kernel lacks an EFI stub"
    mkdir -p "$root$grub_dir" "$root/boot/efi" "$root/usr/lib/modules"
    cp -a "$module_base/$kver" "$root/usr/lib/modules/"
    for name in config System.map; do
        for candidate in "$kernel_root/boot/$name-$kver" \
            "$module_base/$kver/$name"; do
            if [[ -f $candidate ]]; then
                cp "$candidate" "$root/boot/$name-$kver"
                break
            fi
        done
    done
    install -m 644 "$kernel_image" "$root/boot/vmlinuz-$kver"
}
