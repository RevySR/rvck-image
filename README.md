# RVCK / openEuler RVA20 EDK2 镜像工具

`rootfs.sh` 生成 openEuler rootfs，`image.sh` 装入内核并制作磁盘镜像。
更换内核时可以复用 rootfs。默认使用以下 RVA20 仓库：
<https://dl-cdn.openeuler.openatom.cn/openEuler-24.03-LTS-SP3/OS/riscv64/rva20/riscv64/>。
构建和镜像内的 DNF 都只使用此 RVA20 源。

## 构建环境

需要 Linux、root 权限、网络以及 DNF 4、RPM、rpm2cpio、cpio、curl、tar、
util-linux（unshare/losetup 等基础工具）、gdisk（sgdisk）、
dosfstools、e2fsprogs、file、coreutils。
可在 riscv64 主机运行；x86_64/aarch64 主机需要注册带 `F` 标志的
`qemu-riscv64` binfmt_misc，让 RPM scriptlet 和 chroot 中的子进程可以执行。
脚本检查现有注册，不会修改宿主机的 binfmt 配置。

Debian/Ubuntu 依赖：

```sh
sudo apt-get install dnf rpm rpm2cpio cpio curl tar util-linux gdisk \
  dosfstools e2fsprogs file qemu-user-static binfmt-support
sudo update-binfmts --enable qemu-riscv64
cat /proc/sys/fs/binfmt_misc/qemu-riscv64
```

`flags:` 必须包含 `F`。原生 riscv64 主机无需 QEMU user。
在容器内运行时需要 loop 设备及 mount 权限。

## 1. 生成 rootfs

在工具目录执行，替换示例路径。输出目录须已存在。

```sh
sudo ./rootfs.sh \
  --output /path/to/openeuler-rva20-rootfs.tar \
  --ssh-key /path/to/id_ed25519.pub
```

包含 systemd、NetworkManager/DHCP、SSH、DNF、dracut、GRUB 配置工具和 linux-firmware。
默认用户为 `root`，密码为 `openEuler12#$`，可用于串口登录。
如需覆盖默认密码，预先用 `openssl passwd -6` 生成密码哈希文件，
再传入 `--root-password-hash /path/to/root.hash`。
SSH root 密码登录仍禁用；上例配置的公钥可用于 SSH 登录。
首次启动时 systemd/sshd 生成机器 ID 和 SSH 主机密钥。

## 2. 安装 RVCK 内核并生成硬盘镜像

使用 RISC-V 内核 RPM（`--kernel-rpm` 可以重复，以加入拆分的 modules RPM）：

```sh
sudo ./image.sh \
  --rootfs /path/to/openeuler-rva20-rootfs.tar \
  --kernel-rpm /path/to/kernel.riscv64.rpm \
  --output /path/to/rvck-rva20.img \
  --size-gib 8
```

脚本解包 RPM 后运行 depmod 和 dracut，不执行 RPM 安装脚本或更新 RPM 数据库。
内核包需包含配置和同版本模块，支持 `/lib/modules` 和 `/usr/lib/modules`。
内核必须是未压缩的 RISC-V EFI-stub Image。

也可以直接编译已配置的源码树：

```sh
sudo ./image.sh \
  --rootfs /path/to/openeuler-rva20-rootfs.tar \
  --kernel-tree /path/to/linux-tree --cross-compile riscv64-linux-gnu- --jobs "$(nproc)" \
  --output /path/to/rvck-rva20.img
```

源码模式执行 `make Image modules`，再安装到镜像。需要先配置
`.config`，例如 `make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- rvck_defconfig`。
原生 riscv64 构建不需要 `--cross-compile`。工具链和内核构建依赖需自行安装。
需要 RPM 包时，在源码树执行：

```sh
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$(nproc)" binrpm-pkg
```

打包需要 rpmbuild，生成的 RPM 可传给 `--kernel-rpm`。
RPM、源码树、Debian 包三种输入互斥。
`.deb` 可用 `--kernel-deb 文件` 输入（宿主机另需 dpkg-deb），
不运行 Debian 安装钩子。
单独指定 `--kernel-image /path/to/Image` 时，必须与模块同一次构建；
脚本只检查 Image 格式和 EFI stub，不检查它与模块是否来自同一次构建。

## 启动配置

输出为 GPT raw 文件：512 MiB FAT32 ESP，剩余空间为 ext4 根分区。
dracut 为所选内核生成非 host-only initramfs，并加入 virtio 驱动。
内核和 GRUB 都通过文件系统 UUID 查找根分区。
默认命令行 `console=ttyS0,115200 earlycon loglevel=7`，可用 `--cmdline` 替换。
GRUB 设置写入 `/etc/default/grub`，菜单由 rootfs 内的 `grub2-mkconfig`
生成，再用 `grub2-script-check` 检查。BLS 和 os-prober 默认关闭。
硬件描述由 EDK2 提供，不单独加载 DTB。

monolithic GRUB 来自该 RVA20 仓库的 `EFI/BOOT/grubriscv64.EFI`，
固定 SHA-256 为：

```text
bf252892f801347e8ac001613b547d18af4618ddad79909cb133d8f70758fbc5
```

安装为 `EFI/BOOT/BOOTRISCV64.EFI` 和 `EFI/openEuler/grubriscv64.efi`，
生成的配置复制到两个 EFI 目录及 `/boot/grub/grub.cfg`。
替换 EFI 文件时使用 `--grub FILE --grub-sha256 HASH`，
该文件需内嵌菜单所用模块。脚本不签名 EFI 文件。

启动后修改 `/etc/default/grub` 或更换内核时，重新生成并同步配置：

```sh
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo grub2-script-check /boot/grub2/grub.cfg
sudo cp /boot/grub2/grub.cfg /boot/grub/grub.cfg
sudo cp /boot/grub2/grub.cfg /boot/efi/EFI/BOOT/grub.cfg
sudo cp /boot/grub2/grub.cfg /boot/efi/EFI/openEuler/grub.cfg
```

## EDK2 / QEMU 启动示例

从 openEuler 同版本 `virtual_machine_img/riscv64/` 目录准备
`RISCV_VIRT_CODE_RVA20.fd` 和 `RISCV_VIRT_VARS_RVA20.fd`：

```sh
cp RISCV_VIRT_VARS_RVA20.fd rvck-vars.fd
qemu-system-riscv64 \
  -machine virt,pflash0=pflash0,pflash1=pflash1,acpi=off \
  -cpu rv64 -m 4G -smp 4 -nographic \
  -blockdev node-name=pflash0,driver=file,read-only=on,filename=RISCV_VIRT_CODE_RVA20.fd \
  -blockdev node-name=pflash1,driver=file,filename=rvck-vars.fd \
  -drive file=rvck-rva20.img,format=raw,if=none,id=disk0 \
  -device virtio-blk-pci,drive=disk0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0
```

配置公钥后可通过 `ssh -p 2222 root@127.0.0.1` 登录。
官方固件说明：<https://github.com/openeuler-mirror/RISC-V/blob/master/doc/tutorials/vm-qemu-oErv.md>。

## 临时文件

脚本不会覆盖已有输出。临时目录位于输出旁的 `.rvck-rootfs.*` 和
`.rvck-image.*`，运行结束后保留。输出 tar/img 与临时目录中的文件为硬链接。
退出时卸载挂载点并释放 loop 设备。
