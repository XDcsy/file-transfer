# Capture Vision Transfer

一个用于“无网络/无蓝牙时，通过视频链路（显示器 -> 采集卡）传输文件”的 Flutter Windows 工具原型。

实现形态：
- `发送端`：把文件编码成高对比度二值图像帧并循环播放。
- `接收端`：调用 `ffmpeg` 从采集卡抓图，按网格解码图像帧并重组文件。

## 方案设计

### 1. 传输链路

1. 发送机运行本应用发送端，窗口全屏投到采集卡输入的显示输出。
2. 接收机运行本应用接收端，`ffmpeg + dshow` 读取采集卡视频流。
3. 接收端持续解析帧并按分片重组，完成后落盘。

### 2. 图像编码协议（当前实现）

- 网格大小：`120 x 68`（共 `1020 bytes/frame`）
- 帧内结构：
1. `8B` 前导码（用于阈值和方向校验）
2. `40B` 头部（版本、传输 ID、分片索引、分组索引、CRC）
3. 负载（最大 `980B`）
- 分片负载：`864B`（便于奇偶校验和容错）
- 容错机制：
1. 每 `5` 个数据分片生成 `1` 个 XOR parity 分片
2. 每帧 payload 做 `CRC32` 校验
3. 头部做 `CRC16` 校验（基于 CRC32 截断）
- 传输模式：无回传通道，发送端循环广播帧序列，接收端去重并拼装。

### 3. 鲁棒性与效率权衡

- 鲁棒性：
1. 仅用黑白二值编码，降低色彩偏移影响。
2. 网格中心采样 + 动态阈值（基于前导码）适应亮度变化。
3. XOR parity 可恢复每组最多 `1` 个丢失分片。
- 效率：
1. 默认发送 `12 FPS`，可调 `3-30 FPS`。
2. 发送端提供 `重发系数`（1-4），越高越稳，吞吐越低。
3. 实际吞吐约等于：`chunk_payload * fps * 5/6 / repeat`。

## 运行方式（Windows）

## 前置条件

1. 已安装 Flutter（本项目已是 Flutter 工程）。
2. 接收机安装 `ffmpeg`，且可通过命令行调用。
3. 采集卡在 Windows 中可见（DirectShow 视频设备）。

## 启动

1. `flutter run -d windows`
2. 发送机打开 `发送端`：
- 选择文件
- 设置 FPS 与重发系数
- 点击 `开始发送`
- 将窗口拖到目标屏并全屏显示
3. 接收机打开 `接收端`：
- 填 `ffmpeg` 路径
- 扫描或输入采集卡设备名
- 设置采集分辨率/FPS 与解码 FPS
- 设置输出目录
- 点击 `开始接收`

## 设备名获取（手工）

如自动扫描失败，可手工执行：

```bash
ffmpeg -hide_banner -list_devices true -f dshow -i dummy
```

从输出中的 `DirectShow video devices` 区段复制设备名填入界面。

## 当前实现边界

1. 依赖发送画面完整进入采集画面，暂未做透视矫正和自定位。
2. 每组只能恢复 1 个丢失分片，极端丢包下需更高重发或更低 FPS。
3. 文件路径选择器使用 Windows PowerShell 对话框，跨平台仅支持手填路径。

## Windows 一键打包

仓库提供 `tools/package_windows.ps1`，用于在 Windows 主机上生成可直接运行的便携包（包含 ffmpeg）。

在 Windows PowerShell 执行：

```powershell
cd <项目目录>
powershell -ExecutionPolicy Bypass -File .\tools\package_windows.ps1
```

执行后输出：

- 目录：`dist/CaptureVisionTransfer`
- 压缩包：`dist/CaptureVisionTransfer-portable-windows.zip`

## GitHub Actions 打包（Windows Runner）

仓库已提供工作流：`.github/workflows/windows-portable.yml`

触发方式：

1. 打开 GitHub 仓库 `Actions` 页面。
2. 选择 `Build Windows Portable`。
3. 点击 `Run workflow`（可选填 ffmpeg 下载地址）。

产物：

- `CaptureVisionTransfer-portable-windows`（zip 便携包，含 ffmpeg）
- `CaptureVisionTransfer-directory`（解压目录版本）

补充：

- 推送 tag（如 `v1.0.0`）会自动运行并把 zip 附到 GitHub Release。

## 代码结构

- `lib/main.dart`：发送端/接收端 UI 与流程控制，`ffmpeg` 进程管理
- `lib/src/visual_protocol.dart`：分片、CRC、XOR parity、封包与重组
- `lib/src/visual_frame_codec.dart`：帧绘制、图像采样与解码入口
