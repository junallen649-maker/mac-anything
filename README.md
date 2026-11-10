# D:\mac 目录说明

这是 2026-11-10 用 **reims-vgpu** 在 Windows 上跑通 **macOS Sequoia + RTX 3060 GPU 加速** 的完整记录。

## 文件说明

| 文件 | 内容 |
|---|---|
| `reims-vgpu-Windows-macOS-完整复现手册.md` | **主文档**，从 0 开始的完整步骤 + 所有踩过的坑 |
| `config/OpenCore-config.plist` | 实际生效的 OpenCore 配置（ScanPolicy=0, Timeout=20） |
| `config/vm-config.json` | 虚拟机配置（8 vCPU / 8 GB / 128 GB） |
| `config/media.json` | 安装镜像的识别记录（APM/HFS+, x86_64, 15.3 24D60） |
| `config/opencore-manifest.json` | OpenCore 产物清单（含 SHA256） |
| `scripts/prepare-opencore.ps1` | **改过的**引导盘生成脚本（关键改动已应用） |
| `scripts/prepare-opencore.ps1.original` | 原始版本（对比用） |
| `scripts/start.ps1` / `stop.ps1` | 启动/停止脚本 |
| `scripts/environment.ps1` | 环境设置（注意 `MsysRoot` 默认是 `D:\msys64`） |
| `scripts/doctor.ps1` | 环境自检（需 PowerShell 7） |
| `scripts/build-qemu.sh` | 编译 QEMU 的 bash 脚本 |
| `logs/qemu-command.json` | **完整 QEMU 命令行**（复现的最佳参照） |
| `logs/gpu-stats.log` | reims-vgpu 的 GPU 统计原始日志 |
| `logs/GPU-证据-实测帧耗时.txt` | 提取出的 GPU 帧耗时样本 |
| `logs/serial-boot.log` | OpenCore + macOS 内核串口日志（4.3 MB） |

## 核心结论

- **显卡真的在跑**：`window GPU 2.0-2.4 ms avg`
- **macOS 不需要 NVIDIA 驱动**：它驱动的是虚拟的 Apple Paravirtualized GPU
- **VMware 做不到这件事**：它没有 GPU 直通，且 macOS 没有 NVIDIA 驱动

## 代价

- 开 Hyper-V 后 **VMware 全部失效**
- 需要编译（约 1 小时）
- 切换回 VMware 只需关 Hyper-V + 重启

## 最关键的三个坑（必读）

1. **`ScanPolicy = 0x301` 缺 SATA 设备位** → OpenCore 扫不到任何磁盘 → 改 `0`
2. **`prepare-opencore.ps1 -Rebuild` 会用脚本里写死的值覆盖 config** → 必须改脚本本身
3. **`config.plist` 已存在时脚本跳过生成** → 改脚本后要先删 config 再 Rebuild

详见主文档第 4 章。
