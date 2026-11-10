# 在 Windows 上用 RTX 3060 跑 macOS Sequoia（reims-vgpu 方案）

> **本文档基于 2026-11-10 一次完整的实战验证**。
> 最终结果：Windows 11 + Hyper-V/WHPX + QEMU 11.1.50（自编译）+ OpenCore 1.0.8 + reims-vgpu（Vulkan→Metal 翻译层），
> macOS Sequoia 15.3 安装成功并进入桌面，**NVIDIA RTX 3060 通过 Vulkan 实际参与图形渲染（2.2 ms/帧）**。
>
> **这条路 VMware Workstation 永远做不到**，因为它没有 GPU 直通，且 macOS 没有 NVIDIA 驱动。
> reims-vgpu 的巧思在于：让 macOS 以为自己在跟一块 **Apple 半虚拟化 GPU** 通信，
> 背后由宿主机的 Vulkan 驱动（NVIDIA）实际执行绘制。

---

## 目录

- [0. 方案原理](#0-方案原理)
- [1. 硬件与软件要求](#1-硬件与软件要求)
- [2. 与 VMware 方案的对比](#2-与-vmware-方案的对比)
- [3. 从零开始的完整步骤](#3-从零开始的完整步骤)
  - [3.1 开启 Hyper-V / WHPX](#31-开启-hyper-v--whpx)
  - [3.2 安装 MSYS2](#32-安装-msys2)
  - [3.3 安装编译工具链](#33-安装编译工具链)
  - [3.4 安装 Rust（GNU 工具链）](#34-安装-rustgnu-工具链)
  - [3.5 下载 reims-vgpu 与 QEMU 源码](#35-下载-reims-vgpu-与-qemu-源码)
  - [3.6 编译 GPU 固件](#36-编译-gpu-固件)
  - [3.7 编译 Rust dist](#37-编译-rust-dist)
  - [3.8 编译 QEMU](#38-编译-qemu)
  - [3.9 准备 OpenCore 引导盘](#39-准备-opencore-引导盘)
  - [3.10 准备虚拟机磁盘](#310-准备虚拟机磁盘)
  - [3.11 启动并安装 macOS](#311-启动并安装-macos)
- [4. 踩过的坑（重点，能省你两天）](#4-踩过的坑重点能省你两天)
- [5. 文件清单](#5-文件清单)
- [6. 关键配置速查](#6-关键配置速查)
- [7. 日常操作](#7-日常操作)
- [8. 性能实测数据](#8-性能实测数据)
- [9. 故障排查](#9-故障排查)

---

## 0. 方案原理

```
┌──────────────────────────────────────────────────────────┐
│  Windows 11                                              │
│  ├── NVIDIA 驱动 (32.0.16.1742)                          │
│  │   └── Vulkan 运行时                                    │
│  └── Hyper-V / WHPX  (Windows Hypervisor Platform)       │
│       └── QEMU 11.1.50（自编译，含 --enable-pvg）          │
│            ├── OVMF (edk2-x86_64-code.fd)   UEFI 固件     │
│            ├── OpenCore 1.0.8               引导器        │
│            ├── apple-gfx-pci  ← 虚拟 Apple GPU 设备        │
│            │   └── ReimsVgpu.rom  (GPU option ROM)        │
│            │   └── reims_vgpu_c.dll (Vulkan→Metal 翻译)   │
│            └── macOS Sequoia 15.3 guest                  │
│                 └── 用系统自带的 Apple GPU 驱动            │
│                     （以为是真 Apple GPU，实际走 Vulkan）  │
└──────────────────────────────────────────────────────────┘
```

**关键认知**：

1. **macOS 侧不需要 NVIDIA 驱动**。它驱动的是"Apple Paravirtualized Graphics Device"，
   reims-vgpu 在 QEMU 里模拟这个设备的 MMIO 寄存器，把 Metal 命令翻译成 Vulkan 命令。
2. **Apple 封杀的是"物理 NVIDIA 显卡驱动"，不是"任何跟 NVIDIA 沾边的图形栈"**。
   只要 macOS 不直接看到 NVIDIA 设备，就能用 NVIDIA 的算力。
3. **不需要 GPU 直通**。所以不需要 ESXi，不需要双显卡。

---

## 1. 硬件与软件要求

### 1.1 硬件

| 项目 | 要求 | 本次实测配置 |
|---|---|---|
| CPU | Intel/AMD x86_64，**必须支持 AVX / AVX2 / F16C / RDRAND** | Intel i7-12700KF（12核/20线程） |
| 内存 | ≥ 16 GB（给虚拟机 8–16 GB） | 64 GB DDR4-3200 |
| 主板 | **BIOS 里开启 VT-x / AMD-V** | ASUS PRIME B760M-K D4 |
| 显卡 | **支持 Vulkan 的任意 GPU**（NVIDIA/AMD/Intel 都行） | NVIDIA RTX 3060 |
| 磁盘 | 预留 ≥ 60 GB（编译产物 + 虚拟机磁盘） | 致态 Ti600 1 TB NVMe + 4 TB SATA |

**验证 CPU 指令集**（PowerShell）：

```powershell
Get-CimInstance Win32_Processor |
  Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, VirtualizationFirmwareEnabled
```

`VirtualizationFirmwareEnabled` 必须是 `True`（BIOS 已开虚拟化）。

### 1.2 软件

| 软件 | 版本 | 说明 |
|---|---|---|
| Windows | 10 1903+ / 11 | 需要 Hyper-V Platform |
| **MSYS2** | 任意较新版本 | 提供 UCRT64 编译环境 |
| **Rust** | **1.98.1-x86_64-pc-windows-gnu** | ★ 必须是 GNU，不是 MSVC |
| **PowerShell** | **7.2+** | reims 脚本要求，Windows 自带 5.1 不够 |
| Python | 3.9+ | 用于改 plist |
| 7-Zip | 任意 | 解包 OpenCore |
| **macOS 安装镜像** | Sequoia 15.x / Tahoe 26.x | x86_64，APM/HFS+ 或 ISO9660 |

### 1.3 必须关闭/开启的东西

| 项目 | 状态 | 原因 |
|---|---|---|
| **Hyper-V** | ✅ **必须开启** | QEMU 用 WHPX 加速 |
| **HypervisorPlatform** | ✅ **必须开启** | 同上 |
| **VirtualMachinePlatform** | ✅ **必须开启** | 同上 |
| **VMware Workstation** | ❌ **会失效** | 和 Hyper-V 抢 VT-x |
| **Android 模拟器** | ❌ 会失效 | 依赖 Hyper-V |

**代价说明**：开 Hyper-V 后 VMware 就用不了了。想回去就关掉 Hyper-V 重启，VMware 原样恢复（vmdk 文件不受影响）。

---

## 2. 与 VMware 方案的对比

| 维度 | VMware + OC4VM | **reims-vgpu + QEMU** |
|---|---|---|
| macOS 能否启动 | ✅ 可以（Catalina/Sonoma） | ✅ 可以（Sequoia/Tahoe） |
| **GPU 加速** | ❌ 无（虚拟 SVGA，软件渲染） | ✅ **有（RTX 3060 实际渲染）** |
| 显存 | 128 MB 硬上限（`svga.vramSize` 写多大都被截断） | **8 GB 可用** |
| 3D 加速 | 半残（DX12 能开但 VRAM 卡死） | **完整（Vulkan→Metal 全链路）** |
| 图形界面模糊效果 | ❌ 做不到 | ✅ 实时高斯模糊正常 |
| 实时帧耗时 | — | **2.2 ms/帧** |
| 需要重装系统 | 否 | 是（全新安装） |
| 配置复杂度 | 简单 | 复杂（需要编译） |
| 其他虚拟机 | 可共存 | **全部失效**（Hyper-V 独占） |

**结论**：
- **只想体验 macOS** → 用 VMware 方案（简单）
- **需要 GPU 加速 / 跑图形密集应用** → 用 reims-vgpu（本文档）

---

## 3. 从零开始的完整步骤

> **所有路径示例假设**：工作目录 `D:\reims`，MSYS2 装在 `C:\msys64`。
> 如果你的路径不同，全部替换即可。

### 3.1 开启 Hyper-V / WHPX

**管理员 PowerShell**：

```powershell
# 开启三个功能
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart

# 设置启动类型
bcdedit /set hypervisorlaunchtype auto

# 重启
Restart-Computer
```

**重启后验证**：

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent    # 必须 True
Get-Service vmcompute, vmms | Select-Object Name, Status   # 都必须是 Running
```

**验证 Vulkan**（如果装了 Vulkan SDK）：

```powershell
vulkaninfo --summary    # 应该列出 RTX 3060
```

---

### 3.2 安装 MSYS2

**★ 不要用安装器 exe**（Qt Installer Framework 的静默参数不兼容，会失败）。

**用官方 base tarball**：

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$url = 'https://github.com/msys2/msys2-installer/releases/download/2024-01-13/msys2-base-x86_64-20240113.tar.xz'
$out = 'C:\macOS\tools\msys2-base.tar.xz'

# 下载
& $curl -s -L --max-time 900 -o $out $url

# 用 Windows 自带 tar 解压到 C:\
& tar.exe -xJf $out -C 'C:\'

# 验证
Test-Path 'C:\msys64\usr\bin\bash.exe'    # 必须 True
```

**初始化 MSYS2**：

```powershell
& 'C:\msys64\usr\bin\bash.exe' -lc "pacman-key --init; pacman-key --populate msys2; pacman -Sy --noconfirm"
```

---

### 3.3 安装编译工具链

```powershell
$bash = 'C:\msys64\usr\bin\bash.exe'
$pkgs = @(
  'make','diffutils','bison','flex',
  'mingw-w64-ucrt-x86_64-clang',
  'mingw-w64-ucrt-x86_64-llvm',
  'mingw-w64-ucrt-x86_64-llvm-tools',
  'mingw-w64-ucrt-x86_64-lld',
  'mingw-w64-ucrt-x86_64-cmake',
  'mingw-w64-ucrt-x86_64-meson',
  'mingw-w64-ucrt-x86_64-ninja',
  'mingw-w64-ucrt-x86_64-python',
  'mingw-w64-ucrt-x86_64-glib2',
  'mingw-w64-ucrt-x86_64-pixman',
  'mingw-w64-ucrt-x86_64-pkgconf',
  'mingw-w64-ucrt-x86_64-libslirp',
  'mingw-w64-ucrt-x86_64-libusb',
  'mingw-w64-ucrt-x86_64-SDL2',
  'mingw-w64-ucrt-x86_64-vulkan-headers',
  'mingw-w64-ucrt-x86_64-vulkan-loader',
  'mingw-w64-ucrt-x86_64-vulkan-validation-layers',
  'mingw-w64-ucrt-x86_64-spirv-tools',
  'mingw-w64-ucrt-x86_64-qemu',        # ★ 提供 OVMF (edk2-*.fd)
  'git'
) -join ' '

& $bash -lc "pacman -S --noconfirm --needed $pkgs"
```

**验证**：

```powershell
& 'C:\msys64\ucrt64\bin\clang.exe' --version      # 23.x
& 'C:\msys64\ucrt64\bin\cmake.exe' --version      # 4.x
& 'C:\msys64\ucrt64\bin\ninja.exe' --version      # 1.13.x
& 'C:\msys64\ucrt64\bin\meson.exe' --version      # 1.12.x
```

**★ 关键**：`mingw-w64-ucrt-x86_64-qemu` 这个包会带来 OVMF 固件：

```
C:\msys64\ucrt64\share\qemu\edk2-x86_64-code.fd      3.48 MB
C:\msys64\ucrt64\share\qemu\edk2-i386-vars.fd        0.52 MB
```

---

### 3.4 安装 Rust（GNU 工具链）

**★ 必须是 `x86_64-pc-windows-gnu`，不是 MSVC**（MSVC 需要 VS BuildTools 的 link.exe，本方案不需要）。

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$url = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
$out = 'C:\macOS\tools\rustup-init.exe'
& $curl -s -L --max-time 600 -o $out $url

# 先装个基础 rustup
& $out -y --default-toolchain stable --profile minimal

# 装 GNU 工具链
& "$env:USERPROFILE\.cargo\bin\rustup.exe" toolchain install 1.98.1-x86_64-pc-windows-gnu `
    --profile minimal --component rustfmt --component clippy

# ★ 设为默认（重要）
& "$env:USERPROFILE\.cargo\bin\rustup.exe" default 1.98.1-x86_64-pc-windows-gnu
```

**配置 linker**（Rust 的 GNU target 需要一个 linker，用 MSYS2 的 clang）：

```powershell
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CC  = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CXX = 'C:\msys64\ucrt64\bin\clang++.exe'
$env:AR  = 'C:\msys64\ucrt64\bin\llvm-ar.exe'
```

**装 cbindgen**：

```powershell
& "$env:USERPROFILE\.cargo\bin\cargo.exe" install --locked cbindgen --version 0.29.4
```

**装 PowerShell 7**（reims 脚本要求 7.2+）：

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi'
& $curl -s -L -o 'C:\macOS\tools\pwsh7.msi' $url
Start-Process msiexec.exe -ArgumentList '/i','C:\macOS\tools\pwsh7.msi','/quiet','/norestart' -Wait
# 验证
& 'C:\Program Files\PowerShell\7\pwsh.exe' --version
```

---

### 3.5 下载 reims-vgpu 与 QEMU 源码

**★ 不要用 `git clone`**（MSYS2 的 git 可能缺证书链，报 `remote helper 'https' aborted session`）。
**用 zip 下载**：

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$work = 'D:\reims'
New-Item -ItemType Directory -Force -Path $work | Out-Null

# 1. reims-vgpu 的 windows-native-tahoe 分支
& $curl -s -L --max-time 900 -o "$work\reims-vgpu.zip" `
    'https://github.com/tqmane/reims-vgpu/archive/refs/heads/windows-native-tahoe.zip'
Expand-Archive "$work\reims-vgpu.zip" -DestinationPath $work -Force

# 2. QEMU（reims 的自定义分支）
& $curl -s -L --max-time 1200 -o "$work\qemu.zip" `
    'https://github.com/tqmane/qemu-reims-vgpu/archive/refs/heads/windows-native-tahoe.zip'
Expand-Archive "$work\qemu.zip" -DestinationPath "$work\qemu-tmp" -Force

# 3. 把 QEMU 放进 vendor/qemu
$repo = "$work\reims-vgpu-windows-native-tahoe"
$src = Get-ChildItem "$work\qemu-tmp" -Directory | Select-Object -First 1
Remove-Item "$repo\vendor\qemu" -Recurse -Force -ErrorAction SilentlyContinue
Move-Item $src.FullName "$repo\vendor\qemu" -Force

# 验证（应该有 hw/display/apple-gfx-*.c）
Get-ChildItem "$repo\vendor\qemu\hw\display" -Filter 'apple-gfx*'
```

**预期文件**：

```
vendor\qemu\hw\display\apple-gfx.c               ← GPU 主逻辑
vendor\qemu\hw\display\apple-gfx-pci.c           ← PCI 设备
vendor\qemu\hw\display\apple-gfx-mmio.c          ← MMIO 寄存器
vendor\qemu\hw\display\apple-gfx-activity.m      ← Metal 活动桥
vendor\qemu\hw\display\apple-gfx-activity-stub.c
```

---

### 3.6 编译 GPU 固件

GPU 的 option ROM（`ReimsVgpu.rom`），提供 UEFI 显示驱动。

```powershell
$repo   = 'D:\reims\reims-vgpu-windows-native-tahoe'
$bash   = 'C:\msys64\usr\bin\bash.exe'
$buildWin = ($repo + '\.work\target') -replace '\\','/' + '/firmware'
New-Item -ItemType Directory -Force -Path "$repo\.work\target\firmware" | Out-Null

# ★ 关键参数说明：
#   MSYS2_ARG_CONV_EXCL=*  → 防止 MSYS2 把 /nologo、/dll 等 linker 参数误转为路径
#   BUILD=D:/...           → 必须用 Windows 混合路径（cygpath -m 效果），lld-link 才认得
$cmds = @(
  'export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH',
  'export MSYSTEM=UCRT64',
  'export MSYS2_ARG_CONV_EXCL=*',
  'cd /d/reims/reims-vgpu-windows-native-tahoe',
  "make -C firmware OS=Windows_NT BUILD=$buildWin rom",
  'echo MAKE_EXIT=$?'
) -join ' ; '

& $bash -lc $cmds
```

**预期产物**：

```
.work\target\firmware\ReimsVgpu.efi    5.3 KB
.work\target\firmware\ReimsVgpu.rom    5.5 KB   ← 关键
```

---

### 3.7 编译 Rust dist

```powershell
$repo  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$cargo = "$env:USERPROFILE\.cargo\bin\cargo.exe"

# 环境变量（★ 必须全部设置）
$env:RUSTUP_TOOLCHAIN = '1.98.1-x86_64-pc-windows-gnu'    # 覆盖 rust-toolchain.toml 里的 host
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CC  = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CXX = 'C:\msys64\ucrt64\bin\clang++.exe'
$env:CARGO_TARGET_DIR = "$repo\.work\target"
$env:PYTHONUTF8 = '1'
$env:RUSTUP_AUTO_INSTALL = '0'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

Set-Location $repo
& $cargo xtask dist --platform vulkan --profile release
```

**预期产物**（`dist-vulkan\` 下）：

```
lib\libreims_vgpu.a         606 MB
lib\reims_vgpu_c.dll        191 MB
lib\pkgconfig\reims-vgpu.pc
include\reims_vgpu.h
share\reims-vgpu\ReimsVgpu.rom
```

**★ 编译成功后必须修 pc 文件**（生成的是 MSVC 风格，pkg-config 解析会卡住）：

文件：`.work\target\dist-vulkan\lib\pkgconfig\reims-vgpu.pc`

```ini
# 原始（错误的）
Libs: -L${libdir} -lreims_vgpu_c.dll

# 改成
Libs: -L${libdir} -lreims_vgpu_c
```

---

### 3.8 编译 QEMU

```powershell
$repo   = 'D:\reims\reims-vgpu-windows-native-tahoe'
$bash   = 'C:\msys64\usr\bin\bash.exe'
New-Item -ItemType Directory -Force -Path "$repo\build\qemu" | Out-Null

# ---------- configure ----------
# ★ 注意：configure 阶段【不要】设 MSYS2_ARG_CONV_EXCL
#   否则 configure 内部的 cygpath 会把 /d/reims 错误转为 D:/d/reims
# ★ PKG_CONFIG_PATH 用 MSYS2 格式（/d/...），不能用 D:/...
$pkgPath = '/d/reims/reims-vgpu-windows-native-tahoe/.work/target/dist-vulkan/lib/pkgconfig:/c/msys64/ucrt64/lib/pkgconfig'
$cmds = @(
  'export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH',
  'export MSYSTEM=UCRT64',
  'cd /d/reims/reims-vgpu-windows-native-tahoe/build/qemu',
  "export PKG_CONFIG_PATH=$pkgPath",
  'export WINDRES=llvm-windres CC_LD=lld CXX_LD=lld',
  ('../../vendor/qemu/configure --target-list=x86_64-softmmu ' +
   '--cc=clang --cxx=clang++ --extra-ldflags=-fuse-ld=lld ' +
   '--enable-whpx --disable-kvm --disable-hvf ' +
   '--enable-pvg ' +                       # ★ 虚拟 GPU 开关
   '--enable-libusb --enable-sdl --enable-slirp ' +
   '--disable-gtk --disable-vnc --disable-spice ' +
   '--disable-gnutls --disable-curses --disable-nettle ' +
   '--disable-rust --disable-werror'),
  'echo CONFIGURE_EXIT=$?'
) -join ' ; '

& $bash -lc $cmds
```

**configure 成功的标志**：

```
pvg                             : enabled
whpx                            : enabled
reims-vgpu support              : YES 0.1.0
slirp                           : enabled
sdl                             : enabled
CONFIGURE_EXIT=0
```

**然后编译**（写个脚本文件，避免 `bash -lc` 参数传递问题）：

```powershell
$scriptContent = @'
#!/bin/bash
export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
export MSYSTEM=UCRT64
export MSYS2_ARG_CONV_EXCL=*
cd /d/reims/reims-vgpu-windows-native-tahoe/build/qemu || exit 1
echo "=== START $(date) ==="
ninja -j4 qemu-system-x86_64.exe qemu-img.exe qemu-io.exe
code=$?
echo "=== NINJA_EXIT=$code $(date) ==="
exit $code
'@
[System.IO.File]::WriteAllText("$repo\build-qemu.sh", ($scriptContent -replace "`r`n","`n"), (New-Object System.Text.UTF8Encoding($false)))

# 后台跑（约 40-90 分钟）
Start-Process -FilePath 'C:\msys64\usr\bin\bash.exe' -ArgumentList "$repo\build-qemu.sh" `
    -RedirectStandardOutput "$repo\.work\qemu-build.log" `
    -RedirectStandardError "$repo\.work\qemu-build.err" `
    -WindowStyle Hidden
```

**预期产物**：

```
build\qemu\qemu-system-x86_64.exe    71 MB
build\qemu\qemu-img.exe              11 MB
build\qemu\qemu-io.exe               11 MB
```

**★ 编译完必须复制两个文件到 `build\qemu\`**（否则 QEMU 启动时 `0xC0000135` DLL_NOT_FOUND）：

```powershell
$dist = "$repo\.work\target\dist-vulkan"
Copy-Item "$dist\lib\reims_vgpu_c.dll"            "$repo\build\qemu\" -Force
Copy-Item "$dist\share\reims-vgpu\ReimsVgpu.rom"  "$repo\build\qemu\" -Force
```

**验证**：

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;$repo\build\qemu;$env:PATH"
& "$repo\build\qemu\qemu-system-x86_64.exe" --version    # QEMU emulator version 11.1.50
& "$repo\build\qemu\qemu-system-x86_64.exe" -device help | Select-String 'apple-gfx'
# 应该看到：name "apple-gfx-pci", bus PCI, desc "macOS Paravirtualized Graphics PCI Display Controller"
& "$repo\build\qemu\qemu-system-x86_64.exe" -accel help   # 应该列出 tcg 和 whpx
```

---

### 3.9 准备 OpenCore 引导盘

**★ 编译完 reims 后，必须先改脚本里的三个默认值**（否则会踩第 4 节里的循环坑）。

编辑 `scripts\windows\prepare-opencore.ps1`：

```powershell
$script = 'D:\reims\reims-vgpu-windows-native-tahoe\scripts\windows\prepare-opencore.ps1'
Copy-Item $script "$script.bak" -Force

$txt = [System.IO.File]::ReadAllText($script)
# ① 菜单：显示 20 秒（方便手动选安装盘）
$txt = $txt -replace [regex]::Escape("c['Misc']['Boot'].update(HideAuxiliary=False, Timeout=0)"), `
                       "c['Misc']['Boot'].update(HideAuxiliary=False, Timeout=20, ShowPicker=True)"
# ② ScanPolicy：原来 0x301 缺 SATA 设备位，扫不到 QEMU 的磁盘
$txt = $txt -replace 'ScanPolicy=0x301', 'ScanPolicy=0'
# ★ 文件必须 UTF-8 无 BOM（带 BOM 会让含中文的脚本语法报错）
[System.IO.File]::WriteAllText($script, $txt, (New-Object System.Text.UTF8Encoding($false)))
```

**然后生成 OpenCore**：

```powershell
$repo  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'

Set-Location $repo
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:RUSTUP_TOOLCHAIN = '1.98.1-x86_64-pc-windows-gnu'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\prepare-opencore.ps1" `
    -Version 1.0.8 `
    -FirmwareDirectory 'C:\msys64\ucrt64\share\qemu' `
    -Rebuild
```

**预期产物**：

```
vm\firmware\
├── OVMF_CODE.fd                 3.48 MB
├── OVMF_VARS.template.fd        0.52 MB
└── opencore-1.0.8\
    ├── OpenCore.img             504 MB   ← 引导盘
    └── root\EFI\...
```

**验证 img 里的配置**（很重要，确认改动进去了）：

```powershell
$py  = 'C:\Users\<你>\AppData\Local\Programs\Python\Python311\python.exe'
$tmp = "$repo\.work\imgcheck"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'D:\7-Zip\7z.exe' e "$repo\vm\firmware\opencore-1.0.8\OpenCore.img" -o"$tmp" 'EFI/OC/config.plist' -y | Out-Null

& $py -c "import plistlib; p=plistlib.load(open(r'$tmp\config.plist','rb')); print('ScanPolicy =', p['Misc']['Security']['ScanPolicy']); print('Timeout =', p['Misc']['Boot']['Timeout'])"
# 期望：ScanPolicy = 0, Timeout = 20
```

---

### 3.10 准备虚拟机磁盘

```powershell
$repo  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
$iso   = 'D:\path\to\macOS-Sequoia-15.3.iso'      # ← 换成你的镜像路径

Set-Location $repo
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

# 第一步：只检查镜像（不创建任何东西）
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\prepare-vm.ps1" `
    -Iso $iso -InspectOnly -SevenZip 'D:\7-Zip\7z.exe'

# 第二步：正式准备（创建 128 GB qcow2 磁盘）
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\prepare-vm.ps1" `
    -Iso $iso `
    -SevenZip 'D:\7-Zip\7z.exe' `
    -QemuImg "$repo\build\qemu\qemu-img.exe" `
    -DiskGiB 128
```

**`-InspectOnly` 的期望输出**：

```json
{
  "path": "...",
  "container": "APM/HFS+",
  "media_kind": "disk",
  "boot_architecture": "x86_64",
  "product_version": "15.3",
  "product_build": "24D60"
}
```

**正式准备的期望输出**：

```json
{
  "cpus": 8,
  "memory_mib": 8192,
  "resolution": "1920x1080",
  "disk_gib": 128,
  "cpu": "Haswell-noTSX,...+avx2,+aes,...",
  "mac": "52:54:00:xx:xx:xx",
  "qmp_port": 4444,
  "ssh_port": 2222,
  "base_disk": "...vm\\disks\\base.qcow2",
  "active_disk": "...vm\\disks\\current.qcow2",
  "opencore": "...OpenCore.img",
  "firmware_code": "...OVMF_CODE.fd",
  "firmware_vars": "...OVMF_VARS.fd",
  "rom": "...ReimsVgpu.rom"
}
```

---

### 3.11 启动并安装 macOS

**启动**：

```powershell
$repo  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'

Set-Location $repo
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\start.ps1"
```

会弹出一个 **Reims vGPU** 窗口，显示 OpenCore 菜单：

```
OpenCore Boot Menu (REL-108-2026-09-27)

  1. QEMU VVFAT
  2. Install macOS Sequoia [xxx]
  3. Recovery 15.3 (dmg)

|Shutdown|  |Restart|

Choose the Operating System: Timeout
```

**★ 键盘输入的坑**：Reims vGPU 窗口的键盘事件可能不转发给 guest。用 **QMP HMP sendkey** 注入（见第 4.9 节）。

**安装流程**：

1. **选 `Install macOS Sequoia`** → 回车
2. 内核启动约 1–2 分钟，然后进入 **macOS 恢复界面**（图形）
3. 点 **Disk Utility** → 选中 `QEMU HARDDISK`（128 GB）→ **Erase**
   - Name: `Macintosh HD`
   - Format: **APFS**
   - Scheme: **GUID Partition Map**
4. 关闭 Disk Utility，回到主界面
5. 点 **Install macOS Sequoia** → **Continue**
6. 选 `Macintosh HD` → 开始安装（**20–40 分钟**，会自动重启）
7. **重启后如果回到 OpenCore 菜单**，选 **`Macintosh HD`** 继续
8. 装完后进入 **首次设置向导**
9. 完成设置 → **桌面**

**这次实测的时间线**：

```
16:26  启动
16:27  OpenCore 菜单 → 选 Install macOS
16:28  内核启动
16:29  macOS Recovery 图形界面
17:01  安装完成，写入 32.5 GB，重启
17:05  首次设置向导（Select Your Country or Region）
```

---

## 4. 踩过的坑（重点，能省你两天）

> 这一节是整份文档最有价值的部分。每一个坑都实际踩过，有明确的症状和解决方案。

### 4.1 MSYS2 安装器静默参数失败

**症状**：
```
msys2-x86_64-20240113.exe in --confirm-command --root C:/msys64
install exit=1
```
7z 也解不开（`Cannot open the file as archive`）。

**原因**：MSYS2 用的是 Qt Installer Framework，静默参数不兼容。

**解决**：用 **base tarball** + Windows 自带 `tar.exe` 解压（见 3.2）。

---

### 4.2 Rust 默认工具链是 MSVC，缺 link.exe

**症状**：
```
error: linker `link.exe` not found
note: the msvc targets depend on the msvc linker but `link.exe` was not found
```

**原因**：`rustup` 默认装 `stable-x86_64-pc-windows-msvc`，需要 Visual Studio Build Tools。

**解决**：
```powershell
rustup toolchain install 1.98.1-x86_64-pc-windows-gnu
rustup default 1.98.1-x86_64-pc-windows-gnu
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = 'C:\msys64\ucrt64\bin\clang.exe'
```

---

### 4.3 `rust-toolchain.toml` 把工具链拉回 MSVC

**症状**：明明 `rustup default` 设成 GNU 了，`cargo build` 还是报 MSVC linker 错误。

**原因**：仓库的 `rust-toolchain.toml` 写的是：
```toml
[toolchain]
channel = "1.98.1"      ← 没指定 target，rustup 按默认 host（MSVC）解析
targets = ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu", "x86_64-apple-darwin"]
```

**解决**：**用环境变量强制覆盖**（`environment.ps1` 就是这么干的）：
```powershell
$env:RUSTUP_TOOLCHAIN = '1.98.1-x86_64-pc-windows-gnu'
$env:RUSTUP_AUTO_INSTALL = '0'
```

---

### 4.4 firmware 编译：MSYS2 把 `/nologo` 当成路径

**症状**：
```
lld-link: error: could not open 'C:/msys64/nologo': No such file or directory
lld-link: error: could not open 'C:/msys64/dll': No such file or directory
lld-link: error: could not open 'C:/msys64/driver': No such file or directory
```

**原因**：MSYS2 的路径转换把 `/xxx` 形式的 Windows 命令行参数误认为 Unix 路径。

**解决**：设 `MSYS2_ARG_CONV_EXCL=*`：
```bash
export MSYS2_ARG_CONV_EXCL=*
```

**★ 但会引出下一个坑**：

---

### 4.5 `MSYS2_ARG_CONV_EXCL=*` 又让文件路径失效

**症状**：
```
lld-link: error: could not open '/d/reims/.../ReimsVgpu.obj': No such file or directory
```
（文件明明存在）

**原因**：`ARG_CONV_EXCL=*` 同时也禁用了路径转换，`lld-link` 是 Windows 程序，不认 `/d/...` 这种 Unix 路径。

**解决**：**BUILD 参数用 Windows 混合路径**（`cygpath -m` 的效果）：
```bash
# 错误
BUILD=/d/reims/.../firmware
# 正确（Windows 程序能认）
BUILD=D:/reims/.../firmware
```

---

### 4.6 `configure` 时设了 `ARG_CONV_EXCL` 导致路径变成 `D:/d/reims`

**症状**：
```
C:/msys64/ucrt64/bin/python3.exe: can't open file 'D:/d/reims/.../python/scripts/mkvenv.py'
ERROR: python venv creation failed
```

**原因**：`configure` 内部自己调用 `cygpath` 处理路径，外部禁用转换后，`/d/reims` 被当成相对路径拼成了 `D:/d/reims`。

**解决**：**configure 阶段不要设 `MSYS2_ARG_CONV_EXCL`**，只在 `make`/`ninja` 阶段设。

---

### 4.7 pkg-config 找不到 reims-vgpu

**症状**：
```
Found pkg-config: YES (C:\msys64\ucrt64\bin/pkg-config.exe) 3.0.10
Run-time dependency reims-vgpu found: NO (tried pkg-config)
ERROR: Dependency "reims-vgpu" not found (tried pkg-config)
```

**两个原因**：
1. **`PKG_CONFIG_PATH` 用了 `D:/...` 格式** → 改用 MSYS2 格式 `/d/...`
2. **`.pc` 文件里 `Libs: -lreims_vgpu_c.dll`** → `pkg-config --exists` 会**卡死**，改成 `-lreims_vgpu_c`

**解决**：
```powershell
$env:PKG_CONFIG_PATH = '/d/reims/.../dist-vulkan/lib/pkgconfig:/c/msys64/ucrt64/lib/pkgconfig'
# 并手改 .pc 文件去掉 .dll 后缀
```

**验证**：
```bash
pkg-config --exists reims-vgpu; echo "exit=$?"    # 必须是 0
pkg-config --libs reims-vgpu                     # 应该输出 -lreims_vgpu_c
```

---

### 4.8 `QEMU 0xC0000135` (DLL_NOT_FOUND)

**症状**：`qemu-system-x86_64.exe --version` 退出码 `-1073741515`（0xC0000135），无任何输出。

**原因**：`reims_vgpu_c.dll` 不在 `build\qemu\` 目录，也不在 PATH 里。

**解决**：
```powershell
Copy-Item "$repo\.work\target\dist-vulkan\lib\reims_vgpu_c.dll" "$repo\build\qemu\" -Force
Copy-Item "$repo\.work\target\dist-vulkan\share\reims-vgpu\ReimsVgpu.rom" "$repo\build\qemu\" -Force
```

---

### 4.9 ★ `OCB: System has no boot entries` —— 最耗时的坑

**症状**：
```
BdsDxe: starting Boot0001 "UEFI QEMU HARDDISK QM00017 " from Sata(0x2,...)
00:000 00:000 OCB: System has no boot entries
00:002 00:002 OC: Failed to show boot menu!
Halting on critical error
```

**根因链**（这里有三个独立的坑）：

#### 坑 A：`ScanPolicy = 0x301` 缺 SATA 设备位

OpenCore 的 `ScanPolicy` 是位掩码：
```
769 = 0x301 = 0b0011_0000_0001
  bit 0  (1)     = OC_SCAN_FILE_SYSTEM_LOCK    ✓
  bit 8  (256)   = OC_SCAN_ALLOW_FS_APFS       ✓
  bit 9  (512)   = OC_SCAN_ALLOW_FS_HFS        ✓
  bit 16 (65536) = OC_SCAN_ALLOW_DEVICE_SATA   ✗ 缺失！
```

**允许 HFS+/APFS 但不允许扫描 SATA 总线** —— 而 QEMU 把磁盘全挂在 SATA（`sata.2` OpenCore、`sata.3` 系统盘、`sata.4` 安装盘），所以一个都看不见。

**解决**：`ScanPolicy = 0`（全允许）或 `66307`（LOCK+DEVICE_LOCK+APFS+HFS+SATA）

#### 坑 B：`prepare-opencore.ps1 -Rebuild` 会覆盖你的 config

**症状**：手改 `root\EFI\OC\config.plist` 后跑 `-Rebuild`，改动静默失效。

**原因**：脚本从 `Sample.plist` 重新生成 config，值写死在脚本里：
```python
c['Misc']['Boot'].update(HideAuxiliary=False, Timeout=0)
c['Misc']['Security'].update(ScanPolicy=0x301, ...)
```

**解决**：**改脚本本身**（见 3.9）。

#### 坑 C：`config.plist` 已存在 → 脚本跳过生成

**症状**：改了脚本，跑 `-Rebuild`，config 还是旧值。

**原因**：
```powershell
if (!(Test-Path -LiteralPath $plist)) {    ← 只看存不存在！
    ... 生成 config ...
}
```

**解决**：**先删掉 config.plist，再 `-Rebuild`**：
```powershell
Remove-Item "$repo\vm\firmware\opencore-1.0.8\root\EFI\OC\config.plist" -Force
# 然后跑 -Rebuild
```

#### 坑 D：用带 BOM 的 UTF8 写回脚本

**症状**：
```
ParserError: prepare-opencore.ps1:147
```

**原因**：脚本含中文，用 `UTF8Encoding($true)`（带 BOM）写回会破坏语法。

**解决**：永远用 `UTF8Encoding($false)`（无 BOM）：
```powershell
[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
```

---

### 4.10 改 `root/config.plist` 但 img 没更新

**症状**：改了 `root\EFI\OC\config.plist`，QEMU 里行为没变。

**原因**：QEMU 用的是 `OpenCore.img`（打包好的 FAT 镜像），不是 `root\` 目录。

**7z 无法更新**：`7z u OpenCore.img EFI/OC/config.plist` → `System ERROR: 未实现`

**`pyfatfs` 也不行**：`Boot code must start with 0xEB or 0xE9. Is this a FAT partition?`（img 有 MBR 分区表）

**解决**：**只用官方的 `-Rebuild` 重新打包**（脚本内部用 `qemu-img convert -f vvfat -O raw fat:<efiRoot>`）。

**所以**：改 config 的正确姿势是 **改脚本 → 删 config → -Rebuild**，而不是直接改 config 文件。

---

### 4.11 键盘输入没反应

**症状**：OpenCore 菜单里方向键不动；QMP `send-key` 也没用。

**原因**：
- QEMU 配了 `-display none`（显示由 reims-vgpu 自己管）
- 唯一的键盘是 `-device usb-kbd,id=kbd`
- **QMP 的 `send-key` 默认发到 PS/2（i8042）**，而 guest 没有 PS/2 键盘

**解决**：用 **HMP 的 `sendkey`**（走 QEMU monitor，能正确路由）：

```python
# 通过 QMP 调 HMP
{"execute":"human-monitor-command",
 "arguments":{"command-line":"sendkey down"}}
```

**实测有效**：
```
up : {"return": ""}
ret: {"return": ""}
→ 菜单星号移动，回车生效
```

**★ 不要用 `input-send-event`**：在 `-display none` 模式下会崩溃：
```
Unexpected error in object_property_find_err() at qom/object.c:1455:
Property 'qemu-fixed-text-console.device' not found
```

---

### 4.12 安装到一半重启回到 OpenCore 菜单

**症状**：安装器显示"剩余 22 分钟"，然后闪一下回到菜单。

**不是故障**：macOS 安装本来就会重启多次。但 OpenCore 不会自动继续。

**解决**：**重启后在菜单里选 `Macintosh HD`**（安装完成后它会出现在菜单里）。

本次实测：安装器写了 32.5 GB 后重启，选 Macintosh HD 就进了首次设置向导。

---

## 5. 文件清单

### 5.1 完整目录结构（编译后）

```
D:\reims\
├── reims-vgpu-windows-native-tahoe.zip
├── qemu.zip
└── reims-vgpu-windows-native-tahoe\
    ├── Cargo.toml
    ├── rust-toolchain.toml
    ├── scripts\
    │   └── windows\
    │       ├── prepare-opencore.ps1       ← 需改 3 处（ScanPolicy/Timeout/）
    │       ├── prepare-vm.ps1
    │       ├── start.ps1
    │       ├── stop.ps1
    │       ├── doctor.ps1                 ← 环境自检
    │       ├── snapshot.ps1
    │       ├── environment.ps1            ← MsysRoot 默认 D:\msys64，需覆盖
    │       └── ucrt64.cmake
    ├── vendor\
    │   └── qemu\                          ← QEMU 源码（139 MB, 11438 文件）
    │       ├── configure
    │       ├── meson.build
    │       └── hw\display\apple-gfx*.c    ← 虚拟 GPU 实现
    ├── build\
    │   └── qemu\
    │       ├── qemu-system-x86_64.exe     ← 71 MB
    │       ├── qemu-img.exe               ← 11 MB
    │       ├── qemu-io.exe                ← 11 MB
    │       ├── reims_vgpu_c.dll           ← 191 MB（必须复制到这）
    │       └── ReimsVgpu.rom              ← 5.5 KB（必须复制到这）
    ├── .work\
    │   ├── target\
    │   │   ├── dist-vulkan\
    │   │   │   ├── lib\libreims_vgpu.a        606 MB
    │   │   │   ├── lib\reims_vgpu_c.dll       191 MB
    │   │   │   ├── lib\pkgconfig\reims-vgpu.pc
    │   │   │   ├── include\reims_vgpu.h
    │   │   │   └── share\reims-vgpu\ReimsVgpu.rom
    │   │   └── firmware\
    │   │       ├── ReimsVgpu.efi         5.3 KB
    │   │       └── ReimsVgpu.rom         5.5 KB
    │   ├── downloads\OpenCore-1.0.8\
    │   └── logs\
    └── vm\                                ← 虚拟机本体
        ├── firmware\
        │   ├── OVMF_CODE.fd              3.48 MB
        │   ├── OVMF_VARS.fd              0.52 MB
        │   ├── OVMF_VARS.template.fd     0.52 MB
        │   └── opencore-1.0.8\
        │       ├── OpenCore.img          504 MB
        │       ├── ocvalidate.log
        │       └── root\EFI\
        │           ├── BOOT\BOOTx64.efi
        │           └── OC\
        │               ├── OpenCore.efi
        │               ├── config.plist
        │               └── Drivers\
        │                   ├── OpenHfsPlus.efi       40 KB
        │                   ├── OpenPartitionDxe.efi  40 KB
        │                   └── OpenRuntime.efi       24 KB
        ├── disks\
        │   ├── base.qcow2                128 GB（稀疏）
        │   └── current.qcow2             32 GB（装完系统后）
        ├── state\
        │   ├── config.json               VM 配置
        │   ├── media.json                安装镜像记录
        │   └── opencore.json             OpenCore 清单
        └── logs\
            └── 20261110-162614-149\
                ├── command.json          完整 QEMU 命令行
                ├── serial.log            OpenCore + macOS 内核日志
                ├── stderr.log            ★ GPU 统计在这里
                └── qmp-status.json
```

### 5.2 外部依赖（不在 reims 目录里）

| 路径 | 用途 | 大小 |
|---|---|---|
| `C:\msys64\` | MSYS2 环境 | ~3 GB |
| `C:\msys64\ucrt64\share\qemu\edk2-x86_64-code.fd` | OVMF UEFI 固件 | 3.48 MB |
| `C:\msys64\ucrt64\share\qemu\edk2-i386-vars.fd` | OVMF NVRAM 模板 | 0.52 MB |
| `C:\Users\<你>\.cargo\` | Rust 工具链 | ~1.5 GB |
| `C:\Program Files\PowerShell\7\` | PowerShell 7 | ~200 MB |
| `D:\7-Zip\7z.exe` | 7-Zip | — |
| macOS 安装 ISO | Sequoia 15.3 (24D60) | 16.37 GB |

---

## 6. 关键配置速查

### 6.1 OpenCore `config.plist` 关键值

| 键 | 值 | 说明 |
|---|---|---|
| `Misc/Boot/Timeout` | `20` | 菜单等待 20 秒 |
| `Misc/Boot/ShowPicker` | `True` | 显示菜单 |
| `Misc/Boot/HideAuxiliary` | `False` | 显示 Recovery 等辅助项 |
| `Misc/Security/ScanPolicy` | `0` | **全允许**（0x301 缺 SATA 位） |
| `Misc/Security/SecureBootModel` | `x86legacy` | 兼容模式 |
| `Misc/Security/HaltLevel` | `0x80000000` | 出错即 halt |
| `Booter/Quirks/SetupVirtualMap` | `True` | |
| `Booter/Quirks/RebuildAppleMemoryMap` | `True` | |
| `Booter/Quirks/SyncRuntimePermissions` | `True` | |
| `Booter/Quirks/EnableWriteUnprotector` | `False` | |
| `Kernel/Emulate/DummyPowerManagement` | `True` | |
| `Kernel/Add` | **空** | reims 不需要任何 kext |
| `ACPI/Add` | **空** | |
| `NVRAM boot-args` | `-v keepsyms=1 serial=3 debug=0x108` | |
| `UEFI/Drivers` | OpenRuntime + OpenPartitionDxe + OpenHfsPlus | |
| `UEFI/Input/KeySupport` | `True` | |
| `UEFI/Input/KeyForgetThreshold` | `5` | |
| `UEFI/Output/Resolution` | `1920x1080` | |

### 6.2 QEMU 命令行关键参数

从 `vm\logs\<时间戳>\command.json` 可以看到完整参数。关键几段：

```
-accel whpx,hyperv=off                              ← WHPX 加速
-cpu Haswell-noTSX,stepping=3,vendor=GenuineIntel,
     +ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+xsave,+xsaveopt,-arat,enforce
-smp 8,sockets=1,cores=8,threads=1
-m 8192M

-device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc

-drive if=pflash,format=raw,readonly=on,file=...OVMF_CODE.fd
-drive if=pflash,format=raw,file=...OVMF_VARS.fd

-device ich9-ahci,id=sata,addr=0x2
-drive  id=opencore,...,file=...OpenCore.img
-device ide-hd,bus=sata.2,drive=opencore,bootindex=1
-drive  id=disk,format=qcow2,file=...current.qcow2
-device ide-hd,bus=sata.3,drive=disk,rotation_rate=1
-drive  id=installer,format=raw,snapshot=on,file=<你的ISO>
-device ide-hd,bus=sata.4,drive=installer

-vga none                                    ← ★ 不用 QEMU 自带显卡
-device {"driver":"apple-gfx-pci",           ← ★ 虚拟 Apple GPU
         "id":"gfx","bus":"pcie.0","addr":"0x4",
         "displays":1,"resolution":"1920x1080",
         "romfile":".../ReimsVgpu.rom",
         "display-modes":["1920x1080@60","1280x720@60",
                          "2560x1440@60","3840x2160@60"]}

-device qemu-xhci,id=xhci,addr=0x5,p2=8,p3=6,conditional-intr-mapping=on
-device usb-kbd,id=kbd,bus=xhci.0
-device usb-tablet,id=tablet,bus=xhci.0

-netdev user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:2222-:22
-device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:xx:xx:xx,addr=0x3

-display none                                ← 显示由 reims-vgpu 管
-qmp tcp:127.0.0.1:4444,server=on,wait=off
-serial file:.../serial.log
```

### 6.3 虚拟机配置（`vm\state\config.json`）

```json
{
  "cpus": 8,
  "memory_mib": 8192,
  "resolution": "1920x1080",
  "disk_gib": 128,
  "mac": "52:54:00:xx:xx:xx",
  "qmp_port": 4444,
  "ssh_port": 2222
}
```

**想调高配置**：改这个 JSON，然后 `stop.ps1` + `start.ps1`。

---

## 7. 日常操作

### 7.1 启动/停止

```powershell
$repo  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
Set-Location $repo
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

# 启动
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\start.ps1"

# 优雅停止（等 macOS 关机）
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\stop.ps1"

# 强制停止（丢弃未保存工作）
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\stop.ps1" -Force
```

### 7.2 用 QMP 注入按键（键盘不响应时）

```powershell
function Send-HmpKey {
    param([string]$Key)   # up / down / ret / esc / space / tab
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', 4444)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 400
    $r.ReadLine() | Out-Null
    $w.WriteLine('{"execute":"qmp_capabilities"}')
    Start-Sleep -Milliseconds 200
    $r.ReadLine() | Out-Null
    $w.WriteLine('{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ' + $Key + '"}}')
    Start-Sleep -Milliseconds 400
    $r.ReadLine() | Out-Null
    $c.Close()
}

Send-HmpKey 'down'
Send-HmpKey 'ret'
```

### 7.3 截取 guest 画面（不用看窗口）

```powershell
function Get-GuestScreen {
    param([string]$OutPng = 'C:\macOS\tools\screen.png')
    $ppm = $OutPng -replace '\.png$', '.ppm'
    Remove-Item $ppm -Force -ErrorAction SilentlyContinue

    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', 4444)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 300
    $r.ReadLine() | Out-Null
    $w.WriteLine('{"execute":"qmp_capabilities"}')
    Start-Sleep -Milliseconds 150
    $r.ReadLine() | Out-Null
    $w.WriteLine('{"execute":"screendump","arguments":{"filename":"' + ($ppm -replace '\\','/') + '"}}')
    Start-Sleep -Milliseconds 1500
    $r.ReadLine() | Out-Null
    $c.Close()

    python -c "from PIL import Image; Image.open(r'$ppm').save(r'$OutPng')"
    Write-Output $OutPng
}
```

### 7.4 打快照

```powershell
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\snapshot.ps1"
```

### 7.5 看 GPU 实时统计

```powershell
$latest = Get-ChildItem "$repo\vm\logs" -Directory | Sort-Object Name -Descending | Select-Object -First 1
Get-Content "$latest\stderr.log" -Tail 5 -Wait
```

输出示例：
```
reims-vgpu stats: port 0: guest 10.0/s, max gap 101.0 ms;
                  window 10.0/s, max gap 100.9 ms;
                  window GPU 2.09 ms avg, 2.67 ms max
```

`window GPU X ms avg` = 每帧 GPU 耗时。**这就是 RTX 3060 在实际渲染的证据**。

### 7.6 恢复 VMware（关掉 Hyper-V）

```powershell
# 管理员 PowerShell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
bcdedit /set hypervisorlaunchtype off
Restart-Computer
```

重启后 VMware 恢复正常，vmdk 文件不受影响。

---

## 8. 性能实测数据

### 8.1 本次实测（i7-12700KF + RTX 3060 + 8 vCPU / 8 GB）

| 指标 | 数值 | 说明 |
|---|---|---|
| **GPU 每帧耗时** | **2.0–2.4 ms avg, 2.5–3.0 ms max** | 从 `stderr.log` 统计 |
| 静态界面刷新 | 10.0 /s | OpenCore 菜单 |
| 图形界面 | 正常 | Recovery、设置向导、桌面全渲染 |
| **实时高斯模糊** | ✅ 正常 | GPU 渲染（VMware 做不到） |
| 内存占用 | 8.15–8.97 GB | guest 用满配置 |
| 内核启动时间 | ~60 秒 | 从 OpenCore 选单到 Recovery |
| 系统安装时间 | ~35 分钟 | 16:26 → 17:01 |
| 磁盘写入 | 32.5 GB | Sequoia 15.3 完整安装 |

### 8.2 作者公布的数据（RTX 5080）

| 指标 | 数值 |
|---|---|
| Chrome TestUFO | 约 38 FPS |
| Safari WebGL 测试 | 全 22 项通过（含 180 帧、资源生命周期、丢失恢复） |
| 4K 分辨率 | ⚠️ 宽度 > 2048 有已知 tile-texture 失败 |
| 长时间运行 | ⚠️ device loss 未完全验证 |

### 8.3 与 VMware 方案对比

| 指标 | VMware + Sonoma | reims-vgpu + Sequoia |
|---|---|---|
| 图形渲染 | 软件（SVGA） | **硬件（RTX 3060）** |
| 模糊效果 | 做不到 | ✅ |
| 帧耗时 | 不适用 | **2.2 ms** |
| 显存 | 128 MB | **8 GB** |

---

## 9. 故障排查

### 9.1 `doctor.ps1` 报 `Unable to find type [System.Runtime.Intrinsics.X86.X86Base]`

**原因**：用 Windows PowerShell 5.1 跑，脚本要求 PowerShell 7+。

**解决**：用 `C:\Program Files\PowerShell\7\pwsh.exe` 跑。

### 9.2 Startup 报 `Property 'qemu-fixed-text-console.device' not found`

**原因**：用了 QMP `input-send-event`，在 `-display none` 模式下崩溃。

**解决**：改用 HMP `sendkey`（见 7.2）。

### 9.3 IP 地址 / 网络不通

**QEMU 的网络**：`-netdev user`（slirp NAT）+ `hostfwd=tcp:127.0.0.1:2222-:22`

- guest 内 IP 通常是 `10.0.2.15`
- 宿主机通过 `127.0.0.1:2222` SSH 到 guest
- guest 访问外网正常（NAT）

**如果 SSH 连不上**：需要先在 guest 里装 `REIMSTOOLS`（Finder 里的那个磁盘 → `setup.command`）。

### 9.4 想改分辨率

编辑 `vm\state\config.json` 的 `resolution`，或者启动时用 `start.ps1` 的参数。然后 `stop` + `start`。

**已知限制**：> 2048 宽度有 tile-texture 失败风险。

### 9.5 想改 CPU / 内存

编辑 `vm\state\config.json`：
```json
{
  "cpus": 8,          → 改成 12（但不要超过物理核心数）
  "memory_mib": 8192  → 改成 16384
}
```
然后 `stop` + `start`。

### 9.6 磁盘空间不够

`base.qcow2` 是 128 GB 稀疏盘。要扩容：

```powershell
& "$repo\build\qemu\qemu-img.exe" resize "$repo\vm\disks\base.qcow2" 256G
# 然后在 macOS 里用磁盘工具扩 APFS 容器
```

**注意**：`current.qcow2` 是 overlay，扩容前要先合并或重建。

---

## 附录 A：一条命令看完整个流程

```powershell
# 只在环境已准备好时用（工具链、Rust、源码都就位）
$repo  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'

# 1. 编固件
& 'C:\msys64\usr\bin\bash.exe' -lc @'
export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH
export MSYSTEM=UCRT64
export MSYS2_ARG_CONV_EXCL=*
cd /d/reims/reims-vgpu-windows-native-tahoe
make -C firmware OS=Windows_NT BUILD=D:/reims/reims-vgpu-windows-native-tahoe/.work/target/firmware rom
'@

# 2. 编 Rust
$env:RUSTUP_TOOLCHAIN = '1.98.1-x86_64-pc-windows-gnu'
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CC = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CARGO_TARGET_DIR = "$repo\.work\target"
Set-Location $repo
& "$env:USERPROFILE\.cargo\bin\cargo.exe" xtask dist --platform vulkan --profile release

# 3. 复制 DLL 和 ROM
$dist = "$repo\.work\target\dist-vulkan"
Copy-Item "$dist\lib\reims_vgpu_c.dll" "$repo\build\qemu\" -Force
Copy-Item "$dist\share\reims-vgpu\ReimsVgpu.rom" "$repo\build\qemu\" -Force

# 4. 启动
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\windows\start.ps1"
```

---

## 附录 B：参考链接

- **reims-vgpu 主仓库**：https://github.com/steelbrain/reims-vgpu
- **Windows 分支**：https://github.com/tqmane/reims-vgpu/tree/windows-native-tahoe
- **QEMU 分支**：https://github.com/tqmane/qemu-reims-vgpu/tree/windows-native-tahoe
- **metal2vulkan**：https://github.com/tqmane/metal2vulkan
- **OpenCore**：https://github.com/acidanthera/OpenCorePkg
- **reims 文档**：
  - `docs/windows-vm.md` —— Windows VM 准备与管理
  - `docs/IMPLEMENTATION_STATUS.md` —— 实现状态
  - `docs/KNOWN_ISSUES.md` —— 已知问题

---

## 附录 C：本次实测环境快照

```
CPU      : 12th Gen Intel Core i7-12700KF (12C/20T)
主板     : ASUS PRIME B760M-K D4
内存     : 64 GB DDR4-3200
显卡     : NVIDIA GeForce RTX 3060 (驱动 32.0.16.1742)
存储     : 致态 Ti600 1TB NVMe + 4TB SATA
OS       : Windows 11

MSYS2    : 2024-01-13 base
clang    : 23.1.5
cmake    : 4.4.5
ninja    : 1.13.2
meson    : 1.12.1
Rust     : 1.98.1-x86_64-pc-windows-gnu
PowerShell: 7.4.6
QEMU     : 11.1.50 (自编译，--enable-pvg --enable-whpx)
OpenCore : 1.0.8
macOS    : Sequoia 15.3 (24D60)
VM 配置  : 8 vCPU / 8 GB / 128 GB qcow2 / 1920x1080

结果     : ✅ 安装成功，GPU 加速生效（2.2 ms/帧）
测试日期 : 2026-11-10
```

---

**文档版本**：1.0
**编写时间**：2026-11-10
**验证状态**：全部步骤均实际执行并通过
