# Windows 宿主机运行 macOS Sequoia 并启用 NVIDIA GPU 加速

技术方案：QEMU + WHPX + OpenCore + reims-vgpu

---

# 一、方案定义

## 1.1 目标

在 Windows 11 宿主机上：
1. 运行 macOS Sequoia 15.x x86_64 虚拟机
2. 使用宿主机 NVIDIA 显卡参与图形渲染
3. 不使用 PCIe 直通

## 1.2 实现路径

```
Windows 11
├── NVIDIA 驱动 → Vulkan 运行时
├── Hyper-V / Windows Hypervisor Platform (WHPX)
└── QEMU 11.1.50（自编译，启用 --enable-pvg --enable-whpx）
    ├── OVMF (edk2-x86_64-code.fd)           UEFI 固件
    ├── OpenCore 1.0.8                        引导器
    ├── apple-gfx-pci                         虚拟 Apple Paravirtualized GPU
    │   ├── ReimsVgpu.rom                     GPU option ROM
    │   └── reims_vgpu_c.dll                  Vulkan → Metal 命令翻译层
    └── macOS Sequoia 15.3 guest
        └── Apple Paravirtualized Graphics 驱动（macOS 系统自带）
```

## 1.3 技术原理

macOS 驱动栈只调用 `Apple Paravirtualized Graphics` 设备接口。该接口由 QEMU 的 `apple-gfx-pci` 设备实现。设备的 MMIO 读写被 `reims_vgpu_c.dll` 翻译为 Vulkan 调用，由宿主机 GPU 执行。

macOS 不检测、不驱动宿主机物理显卡。Apple 对 NVIDIA 物理显卡驱动的封锁不适用于此路径。

## 1.4 与 VMware Workstation 方案的差异

| 项目 | VMware + OC4VM | QEMU + reims-vgpu |
|---|---|---|
| macOS 启动 | 支持 | 支持 |
| 宿主机 GPU 参与渲染 | 不支持 | 支持 |
| 虚拟显存上限 | 128 MB（`svga.vramSize` 硬编码截断） | 8 GB |
| 图形界面实时模糊 | 无法实现 | 正常 |
| 单帧渲染耗时 | 未测量 | 2.0–3.3 ms |
| GPU 直通 | 不支持 | 不需要 |
| 需要重装 macOS | 否 | 是 |
| 需要编译 | 否 | 是（约 60 分钟） |
| 其他虚拟机共存 | 可以 | 不可以（Hyper-V 独占） |

---

# 二、项目来源与文件出处

## 2.1 使用的三个仓库

本方案依赖三个 GitHub 仓库，全部为 fork 分支，非原作者主线。

### 2.1.1 主程序：tqmane/reims-vgpu（分支 windows-native-tahoe）

```
https://github.com/tqmane/reims-vgpu/tree/windows-native-tahoe
```

| 项目 | 内容 |
|---|---|
| 原始仓库 | `https://github.com/steelbrain/reims-vgpu` |
| 使用的 fork | `https://github.com/tqmane/reims-vgpu` |
| 使用的分支 | `windows-native-tahoe` |
| 提交时间 | 2026-11-01（commit `8f316b5`） |
| 语言 | Rust |
| 星标数 | 679 |
| zip 大小 | 32.2 MB |
| 本地路径 | `D:\reims\reims-vgpu-windows-native-tahoe\` |

该分支相对原始仓库新增：

| 新增内容 | 说明 |
|---|---|
| WHPX 支持 | Windows Hypervisor Platform 加速 |
| UCRT64/LLVM 原生构建 | 不使用 MSVC 工具链 |
| SDL3 Win32/Vulkan 窗口 | 替代 QEMU 自带显示 |
| `scripts/windows/` | 整套 PowerShell 管理脚本 |
| `docs/windows-vm.md` | Windows VM 准备文档 |
| `docs/IMPLEMENTATION_STATUS.md` | 实现状态 |
| `docs/KNOWN_ISSUES.md` | 已知问题清单 |
| `apps/` | Fluent 图形管理器（可选） |

**原始仓库不支持 Windows**。`steelbrain/reims-vgpu` 的 `master` 分支仅支持：

| 宿主类型 | 图形后端 |
|---|---|
| macOS（Apple Silicon） | Metal 直通 |
| Linux + KVM | Vulkan |

因此 Windows 环境必须使用 `tqmane` 的 fork。

### 2.1.2 QEMU 源码：tqmane/qemu-reims-vgpu（分支 windows-native-tahoe）

```
https://github.com/tqmane/qemu-reims-vgpu/tree/windows-native-tahoe
```

| 项目 | 内容 |
|---|---|
| 原始仓库 | `https://github.com/qemu/qemu` |
| 使用的 fork | `https://github.com/tqmane/qemu-reims-vgpu` |
| 使用的分支 | `windows-native-tahoe` |
| QEMU 版本 | 11.1.50 |
| zip 大小 | 42.9 MB |
| 解压后 | 139 MB / 11438 个文件 |
| 本地路径 | `D:\reims\reims-vgpu-windows-native-tahoe\vendor\qemu\` |

该分支相对原版 QEMU 新增的文件：

| 文件 | 大小 | 作用 |
|---|---|---|
| `hw/display/apple-gfx.c` | — | 虚拟 GPU 主体逻辑 |
| `hw/display/apple-gfx-pci.c` | — | PCI 设备注册（设备名 `apple-gfx-pci`） |
| `hw/display/apple-gfx-mmio.c` | — | MMIO 寄存器读写 |
| `hw/display/apple-gfx-activity.m` | — | Metal 活动状态桥接（Objective-C） |
| `hw/display/apple-gfx-activity-stub.c` | — | 非 macOS 宿主的空实现 |

修改的构建配置：

| 文件 | 修改 |
|---|---|
| `meson_options.txt` | 新增 `option('pvg', type: 'feature', value: 'auto')` |
| `hw/display/meson.build` | 新增 `system_ss.add(when: [pvg, 'CONFIG_MAC_PVG_PCI'], ...)` |

### 2.1.3 翻译层：tqmane/metal2vulkan

```
https://github.com/tqmane/metal2vulkan
```

| 项目 | 内容 |
|---|---|
| 仓库 | `https://github.com/tqmane/metal2vulkan` |
| 固定 commit | `7f09d6be92aa98fb8f5cf4d47c8441d2351bc6fb` |
| 获取方式 | Cargo 在编译 `reims-vgpu` 时按 `Cargo.toml` 声明的 rev 自动拉取 |
| 本地路径 | `~/.cargo/git/checkouts/metal2vulkan-*/`（不单独存放） |

作用：把 Metal API 调用翻译为 Vulkan API 调用。

`Cargo.toml` 中的声明：

```toml
metal2vulkan-runtime = { git = "https://github.com/tqmane/metal2vulkan", rev = "7f09d6be92aa98fb8f5cf4d47c8441d2351bc6fb" }
metal2vulkan         = { git = "https://github.com/tqmane/metal2vulkan", rev = "7f09d6be92aa98fb8f5cf4d47c8441d2351bc6fb" }
```

## 2.2 仓库之间的关系

```
tqmane/reims-vgpu (分支 windows-native-tahoe)
│
├── crates/reims-vgpu-core          核心逻辑（架构、设备模型）
├── crates/reims-vgpu-metal         Metal 接口定义（Objective-C 绑定）
├── crates/reims-vgpu-vulkan        Vulkan 后端实现
├── crates/reims-vgpu-window        窗口系统（SDL3 / AppKit）
├── crates/reims-vgpu-c             C ABI 导出 → 编译为 reims_vgpu_c.dll
├── crates/reims-vgpu               公共 crate
├── xtask                           构建工具 → cargo xtask dist --platform vulkan
│
├── vendor/qemu/                    ← tqmane/qemu-reims-vgpu（手动下载放入）
│   ├── configure
│   ├── meson.build
│   └── hw/display/apple-gfx*.c     虚拟 GPU 设备
│
├── firmware/
│   ├── Makefile                    → 编译 ReimsVgpu.rom
│   └── src/
│       ├── ReimsVgpu.c             UEFI 驱动主体
│       ├── GraphicsOutput.c        GOP 实现
│       ├── ComponentName.c         组件名
│       └── OptionRom.S             ROM 包装
│
├── scripts/windows/                 PowerShell 管理脚本
│   ├── bootstrap.ps1               安装依赖
│   ├── build.ps1                   编译流程
│   ├── prepare-opencore.ps1        生成引导盘（★ 需修改）
│   ├── prepare-vm.ps1              准备虚拟机磁盘
│   ├── start.ps1                   启动
│   ├── stop.ps1                    停止
│   ├── snapshot.ps1                快照
│   ├── doctor.ps1                  环境自检
│   └── environment.ps1             环境变量设置
│
└── Cargo.toml
    └── metal2vulkan 依赖           ← tqmane/metal2vulkan（cargo 自动拉取）
```

## 2.3 下载方式

使用 zip 下载，不使用 `git clone`。

**原因**：MSYS2 的 git 在部分 Windows 环境缺少完整 CA 证书链，执行 `git clone https://...` 报错：

```
fatal: remote helper 'https' aborted session
```

即使用 Windows 自带 git，MSYS2 bash 内的 `git submodule update` 仍可能失败。

### 下载命令

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$WORK = 'D:\reims'

# 主程序
& $curl -s -L --max-time 900 `
    -o "$WORK\reims-vgpu.zip" `
    'https://github.com/tqmane/reims-vgpu/archive/refs/heads/windows-native-tahoe.zip'

# QEMU
& $curl -s -L --max-time 1200 `
    -o "$WORK\qemu.zip" `
    'https://github.com/tqmane/qemu-reims-vgpu/archive/refs/heads/windows-native-tahoe.zip'
```

### 解压

```powershell
Expand-Archive "$WORK\reims-vgpu.zip" -DestinationPath $WORK -Force
Expand-Archive "$WORK\qemu.zip"      -DestinationPath "$WORK\qemu-tmp" -Force
```

解压后目录名：

```
D:\reims\
├── reims-vgpu-windows-native-tahoe\        ← 主程序
└── qemu-tmp\
    └── qemu-reims-vgpu-windows-native-tahoe\   ← 需移动到 vendor\qemu
```

### 移动 QEMU 源码到 vendor 目录

zip 包不包含 git submodule，`vendor\qemu` 目录为空，需手动放入：

```powershell
$REPO = 'D:\reims\reims-vgpu-windows-native-tahoe'
$src  = Get-ChildItem 'D:\reims\qemu-tmp' -Directory | Select-Object -First 1

Remove-Item "$REPO\vendor\qemu" -Recurse -Force -ErrorAction SilentlyContinue
Move-Item   $src.FullName        "$REPO\vendor\qemu" -Force
```

### 验证

```powershell
# 文件数量
(Get-ChildItem "$REPO\vendor\qemu" -Recurse -File).Count
# 期望：11438

# 关键文件
Get-ChildItem "$REPO\vendor\qemu\hw\display" -Filter 'apple-gfx*' | Select-Object Name
# 期望输出：
#   apple-gfx-activity-stub.c
#   apple-gfx-activity.m
#   apple-gfx-mmio.c
#   apple-gfx-pci.c
#   apple-gfx.c

# 版本
Get-Content "$REPO\vendor\qemu\VERSION"
# 期望：11.1.50
```

## 2.4 版本锁定矩阵

复现时必须使用以下版本组合。版本不匹配会导致编译失败或运行时崩溃。

| 组件 | 版本 | 锁定方式 |
|---|---|---|
| reims-vgpu | 分支 `windows-native-tahoe` | git 分支引用 |
| QEMU | 11.1.50 | 分支 `windows-native-tahoe` |
| metal2vulkan | commit `7f09d6b` | `Cargo.toml` 的 `rev` 字段 |
| OpenCore | 1.0.8 | `prepare-opencore.ps1 -Version` 参数 |
| Rust | 1.98.1-x86_64-pc-windows-gnu | `RUSTUP_TOOLCHAIN` 环境变量 |
| clang | 23.x | MSYS2 包管理 |
| meson | ≥ 1.6.0 | QEMU 的 `meson.build` 要求 |
| ninja | 任意 | MSYS2 包管理 |
| PowerShell | ≥ 7.2 | 脚本的 `#Requires` 声明 |

**版本冲突案例**：

| 冲突 | 症状 |
|---|---|
| Rust 使用 MSVC 工具链 | `error: linker 'link.exe' not found` |
| meson < 1.6.0 | `meson.build:883: ERROR: Dependency "reims-vgpu" not found` 后续步骤失败 |
| OpenCore ≠ 1.0.8 | `ocvalidate` 报告版本不兼容 |
| PowerShell 5.1 | `Unable to find type [System.Runtime.Intrinsics.X86.X86Base]` |

## 2.5 分支文档位置

仓库内的技术文档（已复制到 `D:\mac\scripts\`）：

| 文档 | 内容 |
|---|---|
| `docs/windows-vm.md` | Windows VM 准备、管理、Fluent 管理器说明 |
| `docs/IMPLEMENTATION_STATUS.md` | 实现状态（2026-10-18 更新） |
| `docs/KNOWN_ISSUES.md` | 已知问题：4K 分辨率、60 FPS、device loss |
| `docs/windows-apple-account.md` | Apple ID 登录步骤 |
| `docs/UPSTREAM_SYNC.md` | 与上游 `steelbrain` 的同步记录 |
| `docs/WEBGL_DIAGNOSIS.md` | WebGL 性能诊断数据 |
| `README.md` | 项目概述与快速开始 |

## 2.6 上游公布的支持范围

来源：`docs/KNOWN_ISSUES.md` 与 `README.md`

**支持**：

| 项目 | 说明 |
|---|---|
| CPU | Intel / AMD x86_64，需 AVX / AVX2 / F16C / RDRAND |
| 宿主 | macOS（Metal）、Linux + KVM（Vulkan）、**Windows + WHPX**（本分支） |
| guest | macOS 13 / 14 / 15 / 26 x86_64 |
| 功能 | 图形加速、Recovery 模式、e1000e 网卡兼容 |

**不支持**：

| 项目 | 原因 |
|---|---|
| Apple Silicon CPU 上运行 Intel macOS | 架构不兼容 |
| 非 Apple 硬件使用 Apple 半虚拟化 GPU 的全部特性 | 部分特性依赖真机固件 |
| Tahoe 的 Liquid Glass 特效 | 需要真机 GPU 特性 |
| macOS 27（Golden Gate）及以上 | Apple Silicon 专用 |
| ESXi | 未适配 |
| 显示宽度 > 2048 px | tile-texture 已知缺陷 |
| 稳定 60 FPS | 未复现 |

**作者实测环境**：

| 宿主 | guest | 结果 |
|---|---|---|
| Intel Mac mini (Late 2014) | Big Sur / Monterey / Ventura / Sonoma / Sequoia | 通过 |
| AMD Ryzen (HP T740) | 同上 | 通过 |
| M3 Max | arm64 macOS 13 / 14 / 15 / 26 | 通过 |
| Linux + RTX 5080 laptop | x86-64 macOS 26 | 通过 |

---

# 三、需要什么

## 3.1 硬件

| 项目 | 要求 | 验证方式 |
|---|---|---|
| CPU | x86_64，支持 AVX / AVX2 / F16C / RDRAND | 见 3.1 |
| 内存 | ≥ 16 GB（虚拟机分配 8–16 GB） | 系统属性 |
| 主板 | BIOS 开启 Intel VT-x 或 AMD-V | 见 3.1 |
| 显卡 | 支持 Vulkan 1.1+（NVIDIA / AMD / Intel 均可） | 见 3.2 |
| 磁盘 | ≥ 80 GB 可用 | 资源管理器 |

**最低可用配置**：8 核 CPU / 16 GB 内存 / 60 GB 磁盘 / 支持 Vulkan 的显卡

## 3.2 软件

| 软件 | 版本要求 | 用途 |
|---|---|---|
| Windows | 10 1903+ / 11 | 宿主机系统 |
| MSYS2 | 2024-01-13 或更新 | 编译环境（UCRT64） |
| Rust | 1.98.1-x86_64-pc-windows-gnu | 编译 reims-vgpu |
| PowerShell | 7.2+ | 运行 reims 脚本 |
| Python | 3.9+ | 修改 plist |
| 7-Zip | 任意 | 解包 OpenCore |
| macOS 安装镜像 | Sequoia 15.x x86_64 | 安装源 |

## 3.3 文件

| 文件 | 来源 | 大小 |
|---|---|---|
| reims-vgpu 源码 | `github.com/tqmane/reims-vgpu` 分支 `windows-native-tahoe` | 33 MB zip |
| QEMU 源码 | `github.com/tqmane/qemu-reims-vgpu` 分支 `windows-native-tahoe` | 43 MB zip |
| OVMF 固件 | MSYS2 包 `mingw-w64-ucrt-x86_64-qemu` | 4 MB |
| OpenCore 1.0.8 | 脚本自动下载 `acidanthera/OpenCorePkg` | 自动 |
| macOS 镜像 | 自备（Sequoia 15.3 24D60） | 16.4 GB |

---

# 四、不需要什么

以下项目**不需要**，确认后跳过：

| 项目 | 说明 |
|---|---|
| VMware Workstation 的 Unlocker 补丁 | 与 QEMU 方案无关 |
| OpenCore Legacy Patcher | 用于真机，虚拟机不需要 |
| 1401 / OpCore-Simplify | 用于真机生成 SSDT，虚拟机不需要 |
| VS BuildTools / Visual Studio | Rust 使用 GNU 工具链，不需要 MSVC linker |
| GPU 直通（PCIe Passthrough） | 本方案不使用 |
| 双显卡 | 本方案不需要第二块显卡 |
| ESXi | 本方案使用 Windows 宿主机 |
| NVIDIA Web Driver | macOS 侧不加载 NVIDIA 驱动 |
| 任何 macOS kext | OpenCore 的 `Kernel/Add` 保持为空 |
| U 盘 / 安装介质 | 直接使用 ISO/IMG 文件 |
| Apple 开发者账号 | 不需要 |

---

# 五、准备工作

## 5.1 验证 CPU 指令集

管理员 PowerShell：

```powershell
Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,VirtualizationFirmwareEnabled
```

判断标准：
- `VirtualizationFirmwareEnabled` 必须为 `True`
- 若为 `False`，进入 BIOS 开启 Intel VT-x（Intel）或 SVM Mode（AMD）

验证 AVX2 / F16C / RDRAND：

```powershell
$cpu = Get-CimInstance Win32_Processor
$cpu.Name
# 输出中若包含 "12th Gen" 或更新（Intel）/ "Ryzen"（AMD），通常已支持全部三项
```

## 5.2 验证 Vulkan

```powershell
Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion
```

驱动版本要求：
- NVIDIA：`3xx.xx` 或更新
- AMD：`Adrenalin 22.x` 或更新

可选验证（安装 Vulkan SDK 后）：

```powershell
vulkaninfo --summary
```

输出中 `deviceName` 应显示实际 GPU 型号。

## 5.3 记录环境信息

后续步骤需要以下值，先记录：

```powershell
# 工作目录（建议非系统盘）
$WORK = 'D:\reims'

# MSYS2 安装路径（本手册默认）
$MSYS = 'C:\msys64'

# 7-Zip 路径
$SEVENZIP = 'D:\7-Zip\7z.exe'

# macOS 镜像路径
$ISO = 'D:\images\macOS-Sequoia-15.3.iso'
```

创建目录：

```powershell
New-Item -ItemType Directory -Force -Path $WORK | Out-Null
```

---

# 六、步骤

## 步骤 1：开启 Hyper-V

**目的**：启用 WHPX（Windows Hypervisor Platform），QEMU 需要它做硬件加速。

管理员 PowerShell：

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
bcdedit /set hypervisorlaunchtype auto
Restart-Computer
```

**重启后验证**：

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
# 必须输出 True

Get-Service vmcompute, vmms | Select-Object Name, Status
# 两个服务的 Status 必须都是 Running

bcdedit /enum "{current}" | Select-String hypervisorlaunchtype
# 必须输出 hypervisorlaunchtype    Auto
```

**副作用**：VMware Workstation、Android 模拟器、WSL2 之外的部分工具将无法运行。

**回滚方法**（后续如需恢复 VMware）：

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
bcdedit /set hypervisorlaunchtype off
Restart-Computer
```

VMware 的 vmdk 文件不受影响，关闭 Hyper-V 后可原样启动。

---

## 步骤 2：安装 MSYS2

**目的**：提供 UCRT64 编译环境（clang、cmake、ninja、meson、pkg-config）。

**不使用安装器 exe**。原因：MSYS2 安装器基于 Qt Installer Framework，静默参数 `in --confirm-command --root` 在部分环境返回退出码 1；7-Zip 无法解包该格式。

**使用官方 base tarball**：

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$url  = 'https://github.com/msys2/msys2-installer/releases/download/2024-01-13/msys2-base-x86_64-20240113.tar.xz'
$out  = "$env:TEMP\msys2-base.tar.xz"

& $curl -s -L --max-time 900 -o $out $url
& tar.exe -xJf $out -C 'C:\'
```

**验证**：

```powershell
Test-Path 'C:\msys64\usr\bin\bash.exe'
# 必须输出 True

Get-ChildItem 'C:\msys64' | Select-Object Name
# 应包含 ucrt64 目录
```

**初始化**：

```powershell
& 'C:\msys64\usr\bin\bash.exe' -lc "pacman-key --init; pacman-key --populate msys2; pacman -Sy --noconfirm"
```

**预期末尾输出**：`Initial setup complete. MSYS2 is now ready to use.`

---

## 步骤 3：安装编译工具链

**目的**：安装 clang / llvm / cmake / ninja / meson / glib2 / pixman / SDL2 / Vulkan 头文件 / OVMF。

```powershell
$bash = 'C:\msys64\usr\bin\bash.exe'

$packages = @(
  'make',
  'diffutils',
  'bison',
  'flex',
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
  'mingw-w64-ucrt-x86_64-qemu',
  'git'
) -join ' '

& $bash -lc "pacman -S --noconfirm --needed $packages"
```

**注意**：`mingw-w64-ucrt-x86_64-qemu` 仅用于提供 OVMF 固件文件，其自带 QEMU 不使用。

**验证工具链**：

```powershell
& 'C:\msys64\ucrt64\bin\clang.exe'  --version   # 期望 23.x
& 'C:\msys64\ucrt64\bin\cmake.exe'  --version   # 期望 4.x
& 'C:\msys64\ucrt64\bin\ninja.exe'  --version   # 期望 1.13.x
& 'C:\msys64\ucrt64\bin\meson.exe'  --version   # 期望 1.12.x
& 'C:\msys64\ucrt64\bin\pkg-config.exe' --version
```

**验证 OVMF 存在**：

```powershell
Get-ChildItem 'C:\msys64\ucrt64\share\qemu' -Filter 'edk2-x86_64-code.fd'
# 必须存在，约 3.48 MB

Get-ChildItem 'C:\msys64\ucrt64\share\qemu' -Filter 'edk2-i386-vars.fd'
# 必须存在，约 0.52 MB
```

---

## 步骤 4：安装 Rust（GNU 工具链）

**目的**：编译 reims-vgpu 的 Rust 代码。

**使用 GNU 工具链，不使用 MSVC**。原因：MSVC 工具链需要 Visual Studio Build Tools 的 `link.exe`，GNU 工具链使用 MSYS2 的 `clang.exe` 作为 linker，无需额外安装。

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$url  = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
$out  = "$env:TEMP\rustup-init.exe"

& $curl -s -L --max-time 600 -o $out $url
& $out -y --default-toolchain stable --profile minimal

# 安装 GNU 工具链
& "$env:USERPROFILE\.cargo\bin\rustup.exe" toolchain install 1.98.1-x86_64-pc-windows-gnu --profile minimal --component rustfmt --component clippy

# 设为默认
& "$env:USERPROFILE\.cargo\bin\rustup.exe" default 1.98.1-x86_64-pc-windows-gnu
```

**配置 linker 环境变量**（当前会话）：

```powershell
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CC  = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CXX = 'C:\msys64\ucrt64\bin\clang++.exe'
$env:AR  = 'C:\msys64\ucrt64\bin\llvm-ar.exe'
```

**安装 cbindgen**：

```powershell
& "$env:USERPROFILE\.cargo\bin\cargo.exe" install --locked cbindgen --version 0.29.4
```

**验证**：

```powershell
& "$env:USERPROFILE\.cargo\bin\rustc.exe"    --version   # 期望 1.98.1
& "$env:USERPROFILE\.cargo\bin\cbindgen.exe" --version   # 期望 cbindgen 0.29.4
```

---

## 步骤 5：安装 PowerShell 7

**目的**：reims 的 PowerShell 脚本要求 `#Requires -Version 7.2`。Windows 自带 PowerShell 5.1 不支持脚本中使用的 .NET Core 类型 `System.Runtime.Intrinsics.X86.X86Base`。

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$url  = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi'
$out  = "$env:TEMP\pwsh7.msi"

& $curl -s -L --max-time 600 -o $out $url
Start-Process msiexec.exe -ArgumentList '/i', $out, '/quiet', '/norestart' -Wait
```

**验证**：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' --version
# 期望输出 PowerShell 7.4.6
```

---

## 步骤 6：下载源码

**目的**：获取 reims-vgpu 与配套 QEMU 源码。

**使用 zip 下载，不使用 `git clone`**。原因：MSYS2 的 git 在部分 Windows 环境缺少完整证书链，报错 `fatal: remote helper 'https' aborted session`。

```powershell
$curl = 'C:\Windows\System32\curl.exe'
$WORK = 'D:\reims'

# reims-vgpu
& $curl -s -L --max-time 900 -o "$WORK\reims-vgpu.zip" `
    'https://github.com/tqmane/reims-vgpu/archive/refs/heads/windows-native-tahoe.zip'
Expand-Archive "$WORK\reims-vgpu.zip" -DestinationPath $WORK -Force

# QEMU
& $curl -s -L --max-time 1200 -o "$WORK\qemu.zip" `
    'https://github.com/tqmane/qemu-reims-vgpu/archive/refs/heads/windows-native-tahoe.zip'
Expand-Archive "$WORK\qemu.zip" -DestinationPath "$WORK\qemu-tmp" -Force
```

**将 QEMU 源码放入 vendor 目录**：

```powershell
$REPO = "$WORK\reims-vgpu-windows-native-tahoe"
$src  = Get-ChildItem "$WORK\qemu-tmp" -Directory | Select-Object -First 1

Remove-Item "$REPO\vendor\qemu" -Recurse -Force -ErrorAction SilentlyContinue
Move-Item $src.FullName "$REPO\vendor\qemu" -Force
```

**验证**：

```powershell
Get-ChildItem "$REPO\vendor\qemu\hw\display" -Filter 'apple-gfx*' | Select-Object Name
# 必须包含：
#   apple-gfx.c
#   apple-gfx-pci.c
#   apple-gfx-mmio.c
#   apple-gfx-activity.m
#   apple-gfx-activity-stub.c

(Get-ChildItem "$REPO\vendor\qemu" -Recurse -File).Count
# 期望约 11438
```

---

## 步骤 7：编译 GPU 固件

**目的**：生成 `ReimsVgpu.rom`（虚拟 GPU 的 UEFI option ROM）。

**原理**：`make -C firmware` 使用 clang 编译 EFI 驱动，再用 lld-link 链接，最后用 llvm-objcopy 转为 rom。

```powershell
$REPO  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$bash  = 'C:\msys64\usr\bin\bash.exe'
$BUILD = ($REPO -replace '\\','/') + '/.work/target/firmware'

New-Item -ItemType Directory -Force -Path "$REPO\.work\target\firmware" | Out-Null

$cmd = @(
  'export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH',
  'export MSYSTEM=UCRT64',
  'export MSYS2_ARG_CONV_EXCL=*',
  'cd /d/reims/reims-vgpu-windows-native-tahoe',
  "make -C firmware OS=Windows_NT BUILD=$BUILD rom",
  'echo MAKE_EXIT=$?'
) -join ' ; '

& $bash -lc $cmd
```

**参数说明**：

| 参数 | 作用 | 不设置时的错误 |
|---|---|---|
| `MSYS2_ARG_CONV_EXCL=*` | 禁止 MSYS2 将 `/nologo` `/dll` 等参数转为路径 | `lld-link: error: could not open 'C:/msys64/nologo'` |
| `BUILD=D:/...` | 使用 Windows 混合路径 | `lld-link: error: could not open '/d/reims/.../ReimsVgpu.obj'` |

**验证**：

```powershell
Get-ChildItem "$REPO\.work\target\firmware" -Filter 'ReimsVgpu.*'
# 必须包含：
#   ReimsVgpu.efi   约 5.3 KB
#   ReimsVgpu.rom   约 5.5 KB
```

---

## 步骤 8：编译 Rust dist

**目的**：生成 `reims_vgpu_c.dll`（Vulkan→Metal 翻译层）与 C 头文件。

```powershell
$REPO  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$cargo = "$env:USERPROFILE\.cargo\bin\cargo.exe"

$env:RUSTUP_TOOLCHAIN = '1.98.1-x86_64-pc-windows-gnu'
$env:RUSTUP_AUTO_INSTALL = '0'
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CC  = 'C:\msys64\ucrt64\bin\clang.exe'
$env:CXX = 'C:\msys64\ucrt64\bin\clang++.exe'
$env:CARGO_TARGET_DIR = "$REPO\.work\target"
$env:PYTHONUTF8 = '1'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

Set-Location $REPO
& $cargo xtask dist --platform vulkan --profile release
```

**`RUSTUP_TOOLCHAIN` 必设的原因**：仓库 `rust-toolchain.toml` 内容为 `channel = "1.98.1"`，未指定 target。rustup 按默认 host 解析为 `x86_64-pc-windows-msvc`，导致找不到 `link.exe`。环境变量优先级高于该文件。

**预期编译时间**：3–4 分钟。

**验证产物**：

```powershell
Get-ChildItem "$REPO\.work\target\dist-vulkan" -Recurse -File |
  Select-Object @{n='Path';e={$_.FullName.Replace("$REPO\.work\target\dist-vulkan\",'')}}, @{n='MB';e={[math]::Round($_.Length/1MB,2)}}

# 必须包含：
#   lib\libreims_vgpu.a          约 606 MB
#   lib\reims_vgpu_c.dll         约 191 MB
#   lib\pkgconfig\reims-vgpu.pc
#   include\reims_vgpu.h
#   share\reims-vgpu\ReimsVgpu.rom
```

**修改 pc 文件**：

文件 `.work\target\dist-vulkan\lib\pkgconfig\reims-vgpu.pc`，将：

```ini
Libs: -L${libdir} -lreims_vgpu_c.dll
```

改为：

```ini
Libs: -L${libdir} -lreims_vgpu_c
```

**原因**：`pkg-config` 遇到 `-lxxx.dll` 时 `pkg-config --exists` 会挂起不返回。`-l` 参数只接受库名，不接受文件名后缀。

**验证 pkg-config**：

```powershell
& 'C:\msys64\usr\bin\bash.exe' -lc @'
export PATH=/c/msys64/ucrt64/bin:$PATH
export PKG_CONFIG_PATH=/d/reims/reims-vgpu-windows-native-tahoe/.work/target/dist-vulkan/lib/pkgconfig
pkg-config --exists reims-vgpu; echo "exists_exit=$?"
pkg-config --libs reims-vgpu
'@

# 期望输出：
#   exists_exit=0
#   -LD:/reims/.../dist-vulkan/lib -lreims_vgpu_c
```

---

## 步骤 9：编译 QEMU

**目的**：生成带 `apple-gfx-pci` 设备与 WHPX 支持的 QEMU。

### 10.1 configure

```powershell
$REPO = 'D:\reims\reims-vgpu-windows-native-tahoe'
$bash = 'C:\msys64\usr\bin\bash.exe'

New-Item -ItemType Directory -Force -Path "$REPO\build\qemu" | Out-Null

$PKG = '/d/reims/reims-vgpu-windows-native-tahoe/.work/target/dist-vulkan/lib/pkgconfig:/c/msys64/ucrt64/lib/pkgconfig'

$cmd = @(
  'export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH',
  'export MSYSTEM=UCRT64',
  'cd /d/reims/reims-vgpu-windows-native-tahoe/build/qemu',
  "export PKG_CONFIG_PATH=$PKG",
  'export WINDRES=llvm-windres CC_LD=lld CXX_LD=lld',
  ('../../vendor/qemu/configure --target-list=x86_64-softmmu ' +
   '--cc=clang --cxx=clang++ --extra-ldflags=-fuse-ld=lld ' +
   '--enable-whpx --disable-kvm --disable-hvf --enable-pvg ' +
   '--enable-libusb --enable-sdl --enable-slirp ' +
   '--disable-gtk --disable-vnc --disable-spice ' +
   '--disable-gnutls --disable-curses --disable-nettle ' +
   '--disable-rust --disable-werror'),
  'echo CONFIGURE_EXIT=$?'
) -join ' ; '

& $bash -lc $cmd
```

**configure 阶段不设置 `MSYS2_ARG_CONV_EXCL`**。原因：configure 内部调用 `cygpath` 转换路径，外部禁用转换会使 `/d/reims` 被拼成 `D:/d/reims`，导致 `python venv creation failed`。

**参数说明**：

| 参数 | 作用 |
|---|---|
| `--enable-pvg` | 启用 `apple-gfx` 虚拟 GPU（对应 meson 选项 `pvg`） |
| `--enable-whpx` | 启用 Windows Hypervisor Platform 加速 |
| `--disable-kvm --disable-hvf` | Windows 环境不需要 |
| `--disable-gtk --disable-vnc --disable-spice` | 减少依赖，显示由 reims-vgpu 管理 |
| `--disable-rust` | QEMU 自身的 Rust 组件，不需要 |
| `--enable-sdl --enable-slirp --enable-libusb` | 窗口、用户态网络、USB 设备 |

**成功标志**：

```
pvg                             : enabled
whpx                            : enabled
reims-vgpu support              : YES 0.1.0
slirp                           : enabled
sdl                             : enabled
CONFIGURE_EXIT=0
```

### 10.2 编译

创建脚本文件（避免 `bash -lc` 多行参数传递问题）：

```powershell
$script = @'
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

[System.IO.File]::WriteAllText(
  "$REPO\build-qemu.sh",
  ($script -replace "`r`n", "`n"),
  (New-Object System.Text.UTF8Encoding($false))
)
```

后台执行（预计 40–90 分钟）：

```powershell
Start-Process -FilePath 'C:\msys64\usr\bin\bash.exe' `
  -ArgumentList "$REPO\build-qemu.sh" `
  -RedirectStandardOutput "$REPO\.work\qemu-build.log" `
  -RedirectStandardError  "$REPO\.work\qemu-build.err" `
  -WindowStyle Hidden
```

**监控进度**：

```powershell
Get-Content "$REPO\.work\qemu-build.log" -Tail 1
# 输出形如：[1716/1716] Linking target qemu-system-x86_64.exe
```

**成功标志**：

```
[1716/1716] Linking target qemu-system-x86_64.exe
=== NINJA_EXIT=0 ===
```

### 10.3 复制运行时依赖

```powershell
$REPO = 'D:\reims\reims-vgpu-windows-native-tahoe'
$DIST = "$REPO\.work\target\dist-vulkan"

Copy-Item "$DIST\lib\reims_vgpu_c.dll"           "$REPO\build\qemu\" -Force
Copy-Item "$DIST\share\reims-vgpu\ReimsVgpu.rom" "$REPO\build\qemu\" -Force
```

**必做的原因**：`qemu-system-x86_64.exe` 启动时加载 `reims_vgpu_c.dll`。文件不在同目录时退出码为 `-1073741515`（`0xC0000135`，STATUS_DLL_NOT_FOUND），无任何错误输出。

### 10.4 验证

```powershell
$REPO = 'D:\reims\reims-vgpu-windows-native-tahoe'
$env:PATH = "C:\msys64\ucrt64\bin;$REPO\build\qemu;$env:PATH"

& "$REPO\build\qemu\qemu-system-x86_64.exe" --version
# 期望：QEMU emulator version 11.1.50

& "$REPO\build\qemu\qemu-system-x86_64.exe" -device help | Select-String 'apple-gfx'
# 期望：name "apple-gfx-pci", bus PCI, desc "macOS Paravirtualized Graphics PCI Display Controller"

& "$REPO\build\qemu\qemu-system-x86_64.exe" -accel help
# 期望列出：tcg、whpx
```

---

## 步骤 10：修改 OpenCore 生成脚本

**目的**：修正脚本中三个默认值。不修改会导致 OpenCore 无法识别任何磁盘。

**修改对象**：`scripts\windows\prepare-opencore.ps1`

**修改内容**：

| 行 | 原始值 | 修改为 | 原因 |
|---|---|---|---|
| Boot 段 | `HideAuxiliary=False, Timeout=0` | `HideAuxiliary=False, Timeout=20, ShowPicker=True` | Timeout=0 导致菜单一闪而过，无法手动选择安装盘 |
| Security 段 | `ScanPolicy=0x301` | `ScanPolicy=0` | 0x301 缺少 `OC_SCAN_ALLOW_DEVICE_SATA`（bit 16），QEMU 磁盘全部挂载在 SATA，导致扫描结果为空 |

**执行修改**：

```powershell
$script = 'D:\reims\reims-vgpu-windows-native-tahoe\scripts\windows\prepare-opencore.ps1'

Copy-Item $script "$script.bak" -Force

$txt = [System.IO.File]::ReadAllText($script)

$txt = $txt -replace [regex]::Escape("c['Misc']['Boot'].update(HideAuxiliary=False, Timeout=0)"), `
                       "c['Misc']['Boot'].update(HideAuxiliary=False, Timeout=20, ShowPicker=True)"

$txt = $txt -replace 'ScanPolicy=0x301', 'ScanPolicy=0'

[System.IO.File]::WriteAllText($script, $txt, (New-Object System.Text.UTF8Encoding($false)))
```

**编码说明**：必须使用 `UTF8Encoding($false)`（无 BOM）。使用 `UTF8Encoding($true)` 会给含中文的脚本添加 BOM，导致 PowerShell 报 `ParserError`。

**验证修改**：

```powershell
Select-String -Path $script -Pattern "Misc'\]\['Boot'\]\.update|ScanPolicy="
# 期望输出：
#   L60: c['Misc']['Boot'].update(HideAuxiliary=False, Timeout=20, ShowPicker=True)
#   L64: c['Misc']['Security'].update(ScanPolicy=0, SecureBootModel='x86legacy', ...)
```

**ScanPolicy 位定义参考**：

| 位 | 值 | 常量 | 含义 |
|---|---|---|---|
| 0 | 1 | `OC_SCAN_FILE_SYSTEM_LOCK` | 启用文件系统白名单 |
| 1 | 2 | `OC_SCAN_DEVICE_LOCK` | 启用设备白名单（设置其他设备位时必须启用） |
| 8 | 256 | `OC_SCAN_ALLOW_FS_APFS` | 允许 APFS |
| 9 | 512 | `OC_SCAN_ALLOW_FS_HFS` | 允许 HFS+ |
| 10 | 1024 | `OC_SCAN_ALLOW_FS_ESP` | 允许 EFI 分区 |
| 13 | 8192 | `OC_SCAN_ALLOW_FS_FAT` | 允许 FAT |
| 16 | 65536 | `OC_SCAN_ALLOW_DEVICE_SATA` | 允许 SATA 设备 |
| 19 | 524288 | `OC_SCAN_ALLOW_DEVICE_NVME` | 允许 NVMe 设备 |

`0x301` = 769 = `LOCK(1) + APFS(256) + HFS(512)`，无 SATA 位。
`0` = 不限制，扫描全部。

---

## 步骤 11：生成 OpenCore 引导盘

**前置操作**（关键）：删除已有的 `config.plist`。

```powershell
$REPO = 'D:\reims\reims-vgpu-windows-native-tahoe'
Remove-Item "$REPO\vm\firmware\opencore-1.0.8\root\EFI\OC\config.plist" -Force -ErrorAction SilentlyContinue
```

**原因**：脚本逻辑为：

```powershell
$plist = Join-Path $efiRoot 'EFI/OC/config.plist'
if (!(Test-Path -LiteralPath $plist)) {    # 仅在文件不存在时生成
    ... 从 Docs/Sample.plist 生成 config ...
}
```

文件已存在时脚本跳过生成，导致步骤 10 的修改不生效。

**执行生成**：

```powershell
$REPO  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'

Set-Location $REPO
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:RUSTUP_TOOLCHAIN = '1.98.1-x86_64-pc-windows-gnu'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\prepare-opencore.ps1" `
    -Version 1.0.8 `
    -FirmwareDirectory 'C:\msys64\ucrt64\share\qemu' `
    -Rebuild
```

**参数说明**：

| 参数 | 作用 |
|---|---|
| `-Version 1.0.8` | OpenCore 版本（脚本从 GitHub 下载） |
| `-FirmwareDirectory` | OVMF 所在目录。脚本默认查找 `D:\msys64`、`C:\msys64`、`build\qemu\pc-bios`，本环境需显式指定 |
| `-Rebuild` | 强制重新打包 `OpenCore.img` |

**预期输出**：

```json
{
  "schema": 1,
  "version": "1.0.8",
  "image": "...vm\\firmware\\opencore-1.0.8\\OpenCore.img",
  "image_sha256": "...",
  "config": "...root\\EFI\\OC\\config.plist",
  "config_sha256": "...",
  "ocvalidate": "...ocvalidate.exe",
  "firmware_code": "...vm\\firmware\\OVMF_CODE.fd",
  "firmware_vars_template": "...vm\\firmware\\OVMF_VARS.template.fd",
  "firmware_source": "C:\\msys64\\ucrt64\\share\\qemu",
  "validated": true
}
```

`validated: true` 表示 `ocvalidate` 校验通过。

**验证 img 内的配置已更新**：

```powershell
$REPO = 'D:\reims\reims-vgpu-windows-native-tahoe'
$py   = 'C:\Users\<用户名>\AppData\Local\Programs\Python\Python311\python.exe'
$tmp  = "$REPO\.work\imgcheck"

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
& 'D:\7-Zip\7z.exe' e "$REPO\vm\firmware\opencore-1.0.8\OpenCore.img" -o"$tmp" 'EFI/OC/config.plist' -y | Out-Null

& $py -c "import plistlib; p=plistlib.load(open(r'$tmp\config.plist','rb')); print('ScanPolicy =', p['Misc']['Security']['ScanPolicy']); print('Timeout =', p['Misc']['Boot']['Timeout'])"

# 期望：
#   ScanPolicy = 0
#   Timeout = 20
```

**警告**：不要尝试直接修改 `root/EFI/OC/config.plist` 后单独更新 `OpenCore.img`。7-Zip 不支持更新 FAT 镜像（`System ERROR: 未实现`），`pyfatfs` 无法解析带 MBR 分区表的镜像（`Boot code must start with 0xEB or 0xE9`）。唯一可行方式是修改脚本后重新执行 `-Rebuild`。

---

## 步骤 12：准备虚拟机磁盘

**目的**：创建 128 GB qcow2 磁盘，并建立与安装镜像的关联。

```powershell
$REPO  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
$ISO   = 'D:\images\macOS-Sequoia-15.3.iso'

Set-Location $REPO
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

# 第一步：仅检查镜像格式，不创建任何文件
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\prepare-vm.ps1" `
    -Iso $ISO `
    -InspectOnly `
    -SevenZip 'D:\7-Zip\7z.exe'
```

**检查阶段预期输出**：

```json
{
  "schema": 1,
  "path": "D:\\images\\macOS-Sequoia-15.3.iso",
  "bytes": 17578328064,
  "container": "APM/HFS+",
  "media_kind": "disk",
  "boot_architecture": "x86_64",
  "product_version": "15.3",
  "product_build": "24D60"
}
```

**字段含义**：

| 字段 | 说明 |
|---|---|
| `container` | `APM/HFS+` 或 `ISO9660` |
| `media_kind` | `disk`（作为硬盘挂载）或 `cdrom`（作为光驱挂载） |
| `boot_architecture` | 必须为 `x86_64`。`arm64` 镜像无法在 x86 宿主运行 |

**创建磁盘**：

```powershell
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\prepare-vm.ps1" `
    -Iso $ISO `
    -SevenZip 'D:\7-Zip\7z.exe' `
    -QemuImg "$REPO\build\qemu\qemu-img.exe" `
    -DiskGiB 128
```

**预期输出**：

```json
{
  "cpus": 8,
  "memory_mib": 8192,
  "resolution": "1920x1080",
  "disk_gib": 128,
  "cpu": "Haswell-noTSX,stepping=3,vendor=GenuineIntel,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+xsave,+xsaveopt,-arat,enforce",
  "mac": "52:54:00:xx:xx:xx",
  "qmp_port": 4444,
  "ssh_port": 2222,
  "iso": "D:\\images\\macOS-Sequoia-15.3.iso",
  "media_kind": "disk",
  "base_disk": "...vm\\disks\\base.qcow2",
  "active_disk": "...vm\\disks\\current.qcow2",
  "opencore": "...OpenCore.img",
  "firmware_code": "...OVMF_CODE.fd",
  "firmware_vars": "...OVMF_VARS.fd",
  "rom": "...ReimsVgpu.rom"
}
```

**CPU 型号说明**：`Haswell-noTSX` 提供 AVX2 / F16C / RDRAND，满足 macOS 要求，同时避免暴露宿主机真实 CPU 特性差异。可修改 `vm\state\config.json` 中的 `cpu` 字段。

**修改虚拟机配置**：编辑 `vm\state\config.json`：

```json
{
  "cpus": 8,           // 可改为物理核心数
  "memory_mib": 8192,  // 可改为 16384
  "resolution": "1920x1080"
}
```

---

## 步骤 13：启动并安装 macOS

### 13.1 启动

```powershell
$REPO  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'

Set-Location $REPO
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\start.ps1"
```

**预期输出**：

```
Started PID <pid>, QMP 127.0.0.1:4444, SSH 127.0.0.1:2222.
Logs: D:\reims\...\vm\logs\<时间戳>
```

同时弹出标题为 `Reims vGPU` 的窗口。

**窗口显示内容**：

```
OpenCore Boot Menu (REL-108-2026-09-27)

  1. QEMU VVFAT
  2. Install macOS Sequoia [<卷标>]
  3. Recovery 15.3 (dmg)

|Shutdown|  |Restart|

Choose the Operating System: Timeout
```

| 菜单项 | 说明 |
|---|---|
| `QEMU VVFAT` | OpenCore 自身所在的 FAT 分区，不可选 |
| `Install macOS Sequoia` | 安装镜像 |
| `Recovery 15.3 (dmg)` | 安装镜像内的恢复分区 |
| `Macintosh HD` | 安装完成后出现，系统盘 |

### 13.2 键盘输入

窗口可能不转发键盘事件到 guest。使用 QMP 的 HMP 接口注入按键：

```powershell
function Send-Key {
    param([string]$Key)   # up / down / left / right / ret / esc / space / tab / delete

    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', 4444)
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    Start-Sleep -Milliseconds 400
    $reader.ReadLine() | Out-Null

    $writer.WriteLine('{"execute":"qmp_capabilities"}')
    Start-Sleep -Milliseconds 200
    $reader.ReadLine() | Out-Null

    $writer.WriteLine('{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ' + $Key + '"}}')
    Start-Sleep -Milliseconds 400
    $reader.ReadLine() | Out-Null

    $client.Close()
}

Send-Key 'down'
Send-Key 'ret'
```

**不使用 QMP 的 `send-key`**。该命令将按键发送到 PS/2 控制器（`i8042`），本环境未配置 PS/2 键盘设备，指令无效。

**不使用 QMP 的 `input-send-event`**。该命令在 `-display none` 模式下触发 QEMU 缺陷并崩溃：

```
Unexpected error in object_property_find_err() at qom/object.c:1455:
Property 'qemu-fixed-text-console.device' not found
```

### 13.3 安装流程

| 步骤 | 操作 | 预计耗时 |
|---|---|---|
| 1 | 选择 `Install macOS Sequoia`，回车 | — |
| 2 | 内核启动（`-v` 详细模式，屏幕滚动日志） | 60–120 秒 |
| 3 | 进入 macOS 恢复界面（图形） | — |
| 4 | 打开 `Disk Utility` | — |
| 5 | 选中 `QEMU HARDDISK`（128 GB） | — |
| 6 | 点击 `Erase`，参数：Name=`Macintosh HD`，Format=`APFS`，Scheme=`GUID Partition Map` | 10–30 秒 |
| 7 | 关闭 `Disk Utility` | — |
| 8 | 选择 `Install macOS Sequoia` → `Continue` | — |
| 9 | 选择 `Macintosh HD` | — |
| 10 | 安装（进度条显示剩余时间） | 30–40 分钟 |
| 11 | 自动重启 | — |
| 12 | 若回到 OpenCore 菜单，选择 `Macintosh HD` | — |
| 13 | 首次设置向导 | 5–10 分钟 |
| 14 | 桌面 | — |

### 13.4 设置向导

| 页面 | 建议选择 |
|---|---|
| Country or Region | China |
| Language | 简体中文（可后续在 System Settings → General → Language & Region 修改） |
| Accessibility | Not Now |
| Network | 有线自动连接 |
| Data & Privacy | Continue |
| Transfer Your Data | Don't Transfer |
| Apple ID | Set Up Later |
| Terms and Conditions | Agree |
| Create Computer Account | 用户名 + 密码（记录密码） |
| Siri | 不启用 |
| Analytics | 不共享 |
| Appearance | 任意 |

### 13.5 验证 GPU 加速

**方法一：查看 GPU 统计日志**

```powershell
$REPO = 'D:\reims\reims-vgpu-windows-native-tahoe'
$latest = Get-ChildItem "$REPO\vm\logs" -Directory | Sort-Object Name -Descending | Select-Object -First 1
Get-Content "$latest\stderr.log" -Tail 5
```

预期输出：

```
reims-vgpu stats: port 0: guest 10.0/s, max gap 101.0 ms; window 10.0/s, max gap 100.9 ms; window GPU 2.09 ms avg, 2.67 ms max
```

`window GPU X ms avg` 为每帧 GPU 渲染耗时。正常范围 1.8–3.3 ms。若该值为 `-`，表示当前无图形更新（静态画面）。

**方法二：guest 内查询显示设备**

在 macOS 终端执行：

```bash
system_profiler SPDisplaysDataType
```

预期输出包含：

```
Chipset Model: Apple Paravirtualized Graphics Device
VRAM (Total): 8 GB
```

**方法三：截取 guest 画面**

```powershell
function Get-GuestScreen {
    param([string]$Output = "$env:TEMP\guest-screen.png")

    $ppm = $Output -replace '\.png$', '.ppm'
    Remove-Item $ppm -Force -ErrorAction SilentlyContinue

    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', 4444)
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    Start-Sleep -Milliseconds 300
    $reader.ReadLine() | Out-Null
    $writer.WriteLine('{"execute":"qmp_capabilities"}')
    Start-Sleep -Milliseconds 150
    $reader.ReadLine() | Out-Null
    $writer.WriteLine('{"execute":"screendump","arguments":{"filename":"' + ($ppm -replace '\\','/') + '"}}')
    Start-Sleep -Milliseconds 1500
    $reader.ReadLine() | Out-Null
    $client.Close()

    python -c "from PIL import Image; Image.open(r'$ppm').save(r'$Output')"
    Write-Output $Output
}

Get-GuestScreen
```

---

# 七、日常操作

## 7.1 启动

```powershell
$REPO  = 'D:\reims\reims-vgpu-windows-native-tahoe'
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
Set-Location $REPO
$env:REIMS_MSYS2_ROOT = 'C:\msys64'
$env:PATH = "C:\msys64\ucrt64\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\start.ps1"
```

## 7.2 停止

```powershell
# 正常停止（请求 guest 关机，等待超时）
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\stop.ps1"

# 强制停止（丢弃未保存数据）
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\stop.ps1" -Force
```

## 7.3 快照

```powershell
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\snapshot.ps1"
```

## 7.4 环境自检

```powershell
& $pwsh7 -NoProfile -ExecutionPolicy Bypass -File "$REPO\scripts\windows\doctor.ps1" -RequireWhpx
```

输出 JSON 中检查以下字段：

| 字段 | 期望值 |
|---|---|
| `WhpxFeatureEnabled` | `true` |
| `WhpxHypervisorPresent` | `true` |
| `WhpxCapabilityResult` | `0` |
| `HypervisorPresent` | `true` |
| `GPU` | 包含实际显卡型号 |
| `Tools` | 全部路径非空 |

## 7.5 SSH 连接 guest

guest 需先安装 `REIMSTOOLS`（见 6.6）。安装后：

```bash
ssh -p 2222 <用户名>@127.0.0.1
```

端口映射来源：QEMU 参数 `hostfwd=tcp:127.0.0.1:2222-:22`。

## 7.6 安装 REIMSTOOLS

macOS 桌面上有名为 `REIMSTOOLS` 的磁盘。打开后运行 `setup.command`。

功能：
- 安装宿主机 SSH 公钥
- 启用 SSH 服务
- 设置日语键盘与时区偏好
- 设置 Metal 错误模式
- 配置免密 sudo（仅限 shutdown / restart 命令）

## 7.7 恢复 VMware Workstation

管理员 PowerShell：

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
bcdedit /set hypervisorlaunchtype off
Restart-Computer
```

vmdk 文件不受影响。

---

# 八、故障对照表

## 8.1 编译阶段

| 错误信息 | 原因 | 解决 |
|---|---|---|
| `error: linker 'link.exe' not found` | Rust 使用 MSVC 工具链 | `rustup default 1.98.1-x86_64-pc-windows-gnu`，并设 `CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER` |
| `make: clang: No such file or directory` | PATH 使用 Windows 格式，MSYS2 bash 不识别 | bash 内 PATH 用 `/c/msys64/ucrt64/bin` 格式 |
| `lld-link: error: could not open 'C:/msys64/nologo'` | MSYS2 将 `/nologo` 转为路径 | 设 `MSYS2_ARG_CONV_EXCL=*` |
| `lld-link: error: could not open '/d/reims/.../ReimsVgpu.obj'` | `ARG_CONV_EXCL=*` 同时禁用路径转换 | BUILD 参数改为 `D:/reims/...` |
| `can't open file 'D:/d/reims/.../mkvenv.py'` | configure 阶段设置了 `ARG_CONV_EXCL` | configure 不设该变量 |
| `Dependency "reims-vgpu" not found` | PKG_CONFIG_PATH 格式错误，或 pc 文件 `-lxxx.dll` | 路径用 `/d/...`，pc 文件改 `-lxxx` |
| `qemu-system-x86_64.exe` 退出码 `-1073741515` | 缺 `reims_vgpu_c.dll` | 复制 dll 与 rom 到 `build\qemu\` |
| `Unable to find type [System.Runtime.Intrinsics.X86.X86Base]` | 使用 PowerShell 5.1 | 使用 `C:\Program Files\PowerShell\7\pwsh.exe` |
| `ParserError` 出现在 prepare-opencore.ps1 | 写回时使用了带 BOM 的 UTF8 | 使用 `UTF8Encoding($false)` |

## 8.2 引导阶段

| 现象 | 原因 | 解决 |
|---|---|---|
| `OCB: System has no boot entries` + `OC: Failed to show boot menu!` | `ScanPolicy=0x301` 缺 SATA 位（bit 16） | 改为 `ScanPolicy=0` |
| 同上，修改脚本后仍出现 | `config.plist` 已存在，脚本跳过生成 | 删除 `config.plist` 后执行 `-Rebuild` |
| 同上，删除 config 后仍出现 | 脚本内硬编码的默认值未改 | 修改 `prepare-opencore.ps1` 第 60、64 行 |
| `cannot open device 'disk0': Operation not permitted` | macOS 内在线修改 GPT 分区表 | 不可在线操作，需进入 Recovery |
| 菜单一闪而过 | `Timeout=0` | 改为 `Timeout=20` |
| 方向键无响应 | QMP `send-key` 发到 PS/2 | 改用 HMP `sendkey` |
| QEMU 崩溃 `qemu-fixed-text-console.device not found` | 使用 QMP `input-send-event` | 改用 HMP `sendkey` |
| `Property 'qemu-fixed-text-console.device' not found` | 同上 | 同上 |

## 8.3 安装阶段

| 现象 | 原因 | 解决 |
|---|---|---|
| 安装到一半重启回到菜单 | 正常行为，macOS 安装多次重启 | 菜单中选 `Macintosh HD` |
| `所选宗卷的可用空间不足` | 磁盘容量小于系统需求 | 增大 `-DiskGiB` |
| 图形界面花屏 | 分辨率超过 2048 宽 | 改为 `1920x1080` |

## 8.4 运行阶段

| 现象 | 原因 | 解决 |
|---|---|---|
| `window GPU -` | 画面无更新（静态） | 正常，操作界面后会显示数值 |
| SSH 连接被拒绝 | guest 未安装 REIMSTOOLS | 运行 `setup.command` |
| VMware 无法启动 | Hyper-V 占用 VT-x | 见 6.7 |

---

# 九、关键配置速查

## 9.1 OpenCore config.plist

| 路径 | 值 | 作用 |
|---|---|---|
| `Misc/Boot/Timeout` | `20` | 菜单等待秒数 |
| `Misc/Boot/ShowPicker` | `True` | 显示启动菜单 |
| `Misc/Boot/HideAuxiliary` | `False` | 显示 Recovery 等辅助项 |
| `Misc/Security/ScanPolicy` | `0` | 不限制扫描范围 |
| `Misc/Security/SecureBootModel` | `x86legacy` | 兼容 x86 平台 |
| `Misc/Security/HaltLevel` | `0x80000000` | 错误即 halt |
| `Misc/Security/Vault` | `Optional` | 不校验 EFI 签名 |
| `Misc/Security/DmgLoading` | `Signed` | 允许加载签名 DMG |
| `Booter/Quirks/SetupVirtualMap` | `True` | 建立虚拟内存映射 |
| `Booter/Quirks/RebuildAppleMemoryMap` | `True` | 重建内存映射 |
| `Booter/Quirks/SyncRuntimePermissions` | `True` | 同步运行时权限 |
| `Booter/Quirks/EnableWriteUnprotector` | `False` | 不禁用写保护 |
| `Kernel/Emulate/DummyPowerManagement` | `True` | 替代 XCPM |
| `Kernel/Add` | 空数组 | 不加载任何 kext |
| `ACPI/Add` | 空数组 | 不加载任何 ACPI 表 |
| `NVRAM boot-args` | `-v keepsyms=1 serial=3 debug=0x108` | 详细日志 |
| `UEFI/Drivers` | OpenRuntime / OpenPartitionDxe / OpenHfsPlus | 运行时、分区解析、HFS+ 读取 |
| `UEFI/Input/KeySupport` | `True` | 键盘支持 |
| `UEFI/Input/KeyForgetThreshold` | `5` | 按键去抖阈值 |
| `UEFI/Output/Resolution` | `1920x1080` | 输出分辨率 |

## 9.2 QEMU 命令行

完整参数见 `vm\logs\<时间戳>\command.json`。关键段落：

```
-accel whpx,hyperv=off
-cpu Haswell-noTSX,stepping=3,vendor=GenuineIntel,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+xsave,+xsaveopt,-arat,enforce
-smp 8,sockets=1,cores=8,threads=1
-m 8192M

-device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc

-drive if=pflash,format=raw,readonly=on,file=<OVMF_CODE.fd>
-drive if=pflash,format=raw,file=<OVMF_VARS.fd>

-device ich9-ahci,id=sata,addr=0x2
-drive  id=opencore,if=none,format=raw,snapshot=on,file=<OpenCore.img>
-device ide-hd,bus=sata.2,drive=opencore,bootindex=1
-drive  id=disk,if=none,format=qcow2,file=<current.qcow2>
-device ide-hd,bus=sata.3,drive=disk,rotation_rate=1
-drive  id=installer,if=none,format=raw,snapshot=on,file=<ISO>
-device ide-hd,bus=sata.4,drive=installer

-vga none
-device {"driver":"apple-gfx-pci","id":"gfx","bus":"pcie.0","addr":"0x4",
         "displays":1,"resolution":"1920x1080",
         "romfile":"<ReimsVgpu.rom>",
         "display-modes":["1920x1080@60","1280x720@60","2560x1440@60","3840x2160@60"]}

-device qemu-xhci,id=xhci,addr=0x5,p2=8,p3=6,conditional-intr-mapping=on
-device usb-kbd,id=kbd,bus=xhci.0
-device usb-tablet,id=tablet,bus=xhci.0

-netdev user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:2222-:22
-device virtio-net-pci,netdev=net0,id=net0,mac=<MAC>,addr=0x3

-display none
-qmp tcp:127.0.0.1:4444,server=on,wait=off
-serial file:<serial.log>
-no-shutdown
```

## 9.3 虚拟机配置 vm\state\config.json

```json
{
  "schema": 1,
  "cpus": 8,
  "memory_mib": 8192,
  "resolution": "1920x1080",
  "disk_gib": 128,
  "cpu": "Haswell-noTSX,stepping=3,vendor=GenuineIntel,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+xsave,+xsaveopt,-arat,enforce",
  "mac": "52:54:00:xx:xx:xx",
  "qmp_port": 4444,
  "ssh_port": 2222,
  "iso": "<ISO 路径>",
  "media_kind": "disk",
  "base_disk": "<base.qcow2>",
  "active_disk": "<current.qcow2>",
  "opencore": "<OpenCore.img>",
  "firmware_code": "<OVMF_CODE.fd>",
  "firmware_vars": "<OVMF_VARS.fd>",
  "rom": "<ReimsVgpu.rom>"
}
```

修改 `cpus` / `memory_mib` / `resolution` 后需 `stop` + `start` 生效。

---

# 十、文件清单

## 10.1 编译产物

| 路径 | 大小 | 作用 |
|---|---|---|
| `build\qemu\qemu-system-x86_64.exe` | 71 MB | QEMU 主程序（含 apple-gfx-pci） |
| `build\qemu\qemu-img.exe` | 11 MB | 磁盘镜像工具 |
| `build\qemu\qemu-io.exe` | 11 MB | 磁盘 IO 工具 |
| `build\qemu\reims_vgpu_c.dll` | 191 MB | Vulkan→Metal 翻译层 |
| `build\qemu\ReimsVgpu.rom` | 5.5 KB | GPU option ROM |
| `.work\target\dist-vulkan\lib\libreims_vgpu.a` | 606 MB | 静态库 |
| `.work\target\firmware\ReimsVgpu.efi` | 5.3 KB | UEFI 驱动 |
| `.work\target\firmware\ReimsVgpu.rom` | 5.5 KB | 同上 rom |

## 10.2 虚拟机文件

| 路径 | 大小 | 作用 |
|---|---|---|
| `vm\firmware\OVMF_CODE.fd` | 3.48 MB | UEFI 固件 |
| `vm\firmware\OVMF_VARS.fd` | 0.52 MB | NVRAM 存储 |
| `vm\firmware\opencore-1.0.8\OpenCore.img` | 504 MB | 引导盘 |
| `vm\disks\base.qcow2` | 128 GB（稀疏） | 系统盘基础 |
| `vm\disks\current.qcow2` | 实际写入量 | 系统盘 overlay |

## 10.3 外部依赖

| 路径 | 用途 |
|---|---|
| `C:\msys64\` | 编译环境 |
| `C:\msys64\ucrt64\share\qemu\edk2-x86_64-code.fd` | OVMF code |
| `C:\msys64\ucrt64\share\qemu\edk2-i386-vars.fd` | OVMF vars 模板 |
| `C:\Users\<用户>\.cargo\` | Rust 工具链 |
| `C:\Program Files\PowerShell\7\` | PowerShell 7 |

## 10.4 日志

| 路径 | 内容 |
|---|---|
| `vm\logs\<时间戳>\command.json` | 完整 QEMU 命令行 |
| `vm\logs\<时间戳>\serial.log` | OpenCore 与内核串口输出 |
| `vm\logs\<时间戳>\stderr.log` | GPU 统计（`window GPU X ms`） |
| `vm\logs\<时间戳>\qmp-status.json` | QMP 状态 |

---

# 十一、实测数据

## 11.1 测试环境

```
CPU      : Intel Core i7-12700KF (12C/20T)
主板     : ASUS PRIME B760M-K D4
内存     : 64 GB DDR4-3200
显卡     : NVIDIA GeForce RTX 3060 (驱动 32.0.16.1742)
存储     : 1 TB NVMe + 4 TB SATA
系统     : Windows 11

MSYS2    : 2024-01-13
clang    : 23.1.5
cmake    : 4.4.5
ninja    : 1.13.2
meson    : 1.12.1
Rust     : 1.98.1-x86_64-pc-windows-gnu
PowerShell: 7.4.6
QEMU     : 11.1.50
OpenCore : 1.0.8
macOS    : Sequoia 15.3 (24D60)
VM 配置  : 8 vCPU / 8 GB / 128 GB qcow2 / 1920x1080
```

## 11.2 时间统计

| 阶段 | 耗时 |
|---|---|
| MSYS2 安装 + 初始化 | 8 分钟 |
| 工具链安装 | 12 分钟 |
| 源码下载 | 2 分钟 |
| GPU 固件编译 | 20 秒 |
| Rust dist 编译 | 3 分 17 秒 |
| QEMU configure | 40 秒 |
| QEMU 编译 | 约 28 分钟 |
| OpenCore 生成 | 15 秒 |
| 虚拟机磁盘准备 | 20 秒 |
| macOS 安装 | 35 分钟 |
| **合计** | **约 80 分钟** |

## 11.3 GPU 性能

从 `stderr.log` 提取，共 4797 条有效样本：

```
window GPU 1.80 ms avg, 2.57 ms max
window GPU 2.09 ms avg, 3.03 ms max
window GPU 2.26 ms avg, 3.29 ms max
window GPU 2.96 ms avg, 2.96 ms max
window GPU 3.24 ms avg, 5.56 ms max
window GPU 3.30 ms avg, 5.38 ms max
```

| 指标 | 数值 |
|---|---|
| 单帧 GPU 耗时 | 1.8–3.3 ms（平均） |
| 单帧 GPU 耗时峰值 | 2.6–5.6 ms |
| 静态界面刷新率 | 10 帧/秒 |
| 活跃界面刷新率 | 18–26 帧/秒 |
| 实时高斯模糊 | 正常 |
| 内存占用 | 8.15–8.97 GB |

## 11.4 上游公布数据

来源：`docs/KNOWN_ISSUES.md`（2026-10-18 更新）

| 项目 | 数据 |
|---|---|
| 测试硬件 | M3 Max（arm64）、RTX 5080 laptop（x86-64 Linux） |
| Safari WebGL 测试 | 22 项全通过（含 180 帧、资源生命周期、丢失恢复） |
| Chrome TestUFO | 约 38 帧/秒，存在长帧间隔 |
| 4K 分辨率 | 宽度 > 2048 存在 tile-texture 失败 |
| 长时间运行 | device loss 未完成验证 |
| 稳定 60 帧 | 未复现 |

---

# 十二、参考

| 资源 | 地址 |
|---|---|
| reims-vgpu 主仓库 | `https://github.com/steelbrain/reims-vgpu` |
| Windows 分支 | `https://github.com/tqmane/reims-vgpu/tree/windows-native-tahoe` |
| QEMU 分支 | `https://github.com/tqmane/qemu-reims-vgpu/tree/windows-native-tahoe` |
| metal2vulkan | `https://github.com/tqmane/metal2vulkan` |
| OpenCore | `https://github.com/acidanthera/OpenCorePkg` |
| Windows VM 文档 | 仓库内 `docs/windows-vm.md` |
| 实现状态 | 仓库内 `docs/IMPLEMENTATION_STATUS.md` |
| 已知问题 | 仓库内 `docs/KNOWN_ISSUES.md` |

关键源码文件：

| 文件 | 作用 |
|---|---|
| `vendor/qemu/hw/display/apple-gfx.c` | 虚拟 GPU 主体 |
| `vendor/qemu/hw/display/apple-gfx-pci.c` | PCI 设备注册 |
| `vendor/qemu/hw/display/apple-gfx-mmio.c` | MMIO 寄存器实现 |
| `vendor/qemu/hw/display/apple-gfx-activity.m` | Metal 活动状态桥接 |
| `crates/reims-vgpu-vulkan/` | Vulkan 后端 |
| `crates/reims-vgpu-metal/` | Metal 接口定义 |
| `crates/reims-vgpu-c/` | C ABI 导出 |

---

文档版本：2.0
编写日期：2026-11-10
验证状态：全部步骤经实际执行验证
