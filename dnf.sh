# SPDX-License-Identifier: GPL-2.0
# Host DNF is independent of the package manager installed in the rootfs.
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
