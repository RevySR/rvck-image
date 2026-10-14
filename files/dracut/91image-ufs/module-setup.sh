#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
check() {
    return 0
}

depends() {
    echo kernel-modules
}

installkernel() {
    # Symbol-based storage detection can find ufshcd-core but miss the host
    # drivers. Include both current and older kernel UFS directory layouts.
    # Missing directories are optional for kernels without modular UFS.
    hostonly='' instmods -o '=drivers/ufs' '=drivers/scsi/ufs'
}
