# SPDX-License-Identifier: GPL-2.0
label=openRuyi
releasever=Creek
hostname=openruyi
package_list=installiso.list
# Keep repository kernels out of this reusable userspace archive.
kernel_excludes="linux linux-core linux-modules linux-dtbs"
bootstrap=(filesystem bash coreutils glibc shadow dnf5 rpm
    ca-certificates ca-certificates-mozilla)
weak_deps=True
gpgcheck=False
repo_key=
configure_rootfs() {
    chroot "$root" groupadd -f wheel
    chroot "$root" groupadd -f openruyi
    if ! chroot "$root" id openruyi >/dev/null 2>&1; then
        chroot "$root" useradd -m -g openruyi -G wheel \
            -s /bin/bash openruyi
    fi
    # Keep the root/openruyi credentials selected in image.kiwi.
    hash='$1$xyz$bK93SeXkJSOeaFfdbGu9f.'
    [[ -z $password_hash ]] || hash=$(cat "$password_hash")
    printf 'root:%s\nopenruyi:%s\n' "$hash" "$hash" \
        | chroot "$root" chpasswd -e
    chroot "$root" authselect select openruyi-local --force --nobackup
    if [[ -n $ssh_key ]]; then
        [[ -s $ssh_key ]] || die "empty SSH public key"
        for home in root home/openruyi; do
            install -d -m 700 "$root/$home/.ssh"
            install -m 600 "$ssh_key" "$root/$home/.ssh/authorized_keys"
        done
        chroot "$root" chown -R openruyi:openruyi /home/openruyi/.ssh
    fi
    chroot "$root" systemctl preset-all
    for unit in sshd.socket systemd-homed.service \
        systemd-networkd-persistent-storage.service \
        systemd-boot-update.service; do
        if [[ -e $root/usr/lib/systemd/system/$unit ]]; then
            chroot "$root" systemctl disable "$unit"
        fi
    done
    mkdir -p "$root/etc/repart.d" "$root/etc/cloud/cloud.cfg.d"
    cat > "$root/etc/repart.d/50-root.conf" <<EOF
[Partition]
Type=root-riscv64
GrowFileSystem=yes
EOF
    cat > "$root/etc/cloud/cloud.cfg.d/90-image.cfg" <<EOF
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Ec2, None ]
system_info:
  default_user:
    name: openruyi
    groups: [wheel]
    shell: /bin/bash
    lock_passwd: false
EOF
}
