# SPDX-License-Identifier: GPL-2.0
# Host DNF is independent of the package manager installed in the rootfs.
configure_rpm_database() {
    local macro_path macro_file
    # Both target distributions use /var/lib/rpm and NDB. Host RPM defaults
    # (notably Debian's per-user path and SQLite backend) are not portable.
    # Override the last loaded macro file only inside our private mount
    # namespace. Chroot scriptlets still load the target's native macros.
    macro_path=$(LC_ALL=C rpm --showrc | sed -n 's/^Macro path: //p')
    [[ -n $macro_path ]] || die "cannot determine host RPM macro path"
    macro_path=$(rpm --eval "$macro_path")
    macro_file=$(python3 - "$macro_path" <<'PY'
import glob, os, sys
files = [f for pattern in sys.argv[1].split(':')
         for f in sorted(glob.glob(os.path.expanduser(pattern)))
         if os.path.isfile(f)]
if not files:
    sys.exit('cannot find host RPM macro files')
print(os.path.realpath(files[-1]))
PY
    )
    cat "$macro_file" > "$work/rpm.macros"
    printf '\n%%_dbpath /var/lib/rpm\n%%_db_backend ndb\n' >> "$work/rpm.macros"
    mount --bind "$work/rpm.macros" "$macro_file"
    mounts+=("$macro_file")
    [[ $(rpm --eval '%{_dbpath}:%{_db_backend}') == /var/lib/rpm:ndb ]] \
        || die "cannot override host RPM database configuration"
    # Fail before downloading/installing packages if host RPM lacks NDB.
    rpm --root "$root" --initdb
    [[ -f $root/var/lib/rpm/Packages.db ]] \
        || die "host RPM must support the NDB database backend"
}

select_dnf() {
    local candidate version
    if [[ $dnf_command == auto ]]; then
        dnf_command=
        for candidate in dnf5 dnf dnf4; do
            if command -v "$candidate" >/dev/null; then
                dnf_command=$candidate
                break
            fi
        done
        [[ -n $dnf_command ]] || die "install required tools: dnf5 or dnf (DNF4)"
    fi
    need "$dnf_command"
    version=$(LC_ALL=C "$dnf_command" --version) \
        || die "cannot determine DNF version: $dnf_command"
    version=${version%%$'\n'*}
    # `dnf` can point to either major version; do not infer it from the name.
    [[ $version =~ (^|[[:space:]])([45])\.[0-9] ]] \
        || die "expected DNF4 or DNF5: $dnf_command ($version)"
    dnf_major=${BASH_REMATCH[2]}
}

configure_dnf_args() {
    dnf_cache_config= dnf_log_config=
    dnf_args=(-y --config="$work/dnf.conf"
        --installroot="$root" --releasever="$releasever" --forcearch=riscv64
        --setopt="reposdir=$work/repos" --setopt=plugins=0)
    if [[ $dnf_major == 5 ]]; then
        dnf_args+=(--use-host-config --setopt="system_cachedir=$cache_dir"
            --setopt="logdir=$work/log"
            --disable-repo='*' --enable-repo="image-$distro-$isa")
    else
        # DNF4 prepends installroot to paths from its config file. Use paths
        # relative to that root to retain the host cache and staging logs.
        # Do not use --setopt here: DNF4 reapplies it after configuring repos.
        dnf_cache_config="cachedir=/$(realpath --relative-to="$root" "$cache_dir")"
        dnf_log_config="logdir=/$(realpath -m --relative-to="$root" "$work/log")"
        dnf_args+=(--disablerepo='*' --enablerepo="image-$distro-$isa")
    fi
    if [[ $distro == euler ]]; then
        dnf_args+=(--setopt=module_platform_id=platform:oe2403)
    fi
}
