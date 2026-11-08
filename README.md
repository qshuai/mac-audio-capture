# MacAudioCapture（sysaudio）

录下 Mac 正在播放的声音。基于 ScreenCaptureKit 的系统音频内录工具，会把浏览器、播放器、会议软件等**系统输出的音频**保存成 WAV / M4A / MP3 文件——不需要安装 BlackHole、Soundflower 这类虚拟声卡，也不会录入麦克风或本程序自己的声音。

## 环境要求

- macOS 13.0 或更高版本（开发验证环境：macOS 27.0.1 / Apple Silicon）
- Command Line Tools 或 Xcode 中的 `clang`（`xcode-select --install` 可安装）
- `ffmpeg`：**可选**，仅在输出 M4A / MP3 时需要；输出 WAV 不依赖它

## 编译

```bash
./build.sh
```

产出两个文件，均在 `dist/`：

- `sysaudio`：命令行程序，可直接使用或复制到 `PATH`
- `SysAudioCapture.app`：带权限声明（`Info.plist`）并做过 ad-hoc 签名的独立 App，需要给 App 单独授权时使用

构建脚本用 `clang` 编译 Objective-C 源码，链接 Foundation / ScreenCaptureKit / CoreMedia / CoreVideo / ApplicationServices。

## 权限（首次使用必做）

程序需要「屏幕与系统音频录制」权限：

```bash
./dist/sysaudio --check               # 查看当前权限状态
./dist/sysaudio --request-permission  # 打开授权弹窗与系统设置面板
```

在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中，为**启动它的终端 / iTerm**（或 `SysAudioCapture.app`）打开开关，授权后重新运行命令；必要时重启终端。程序只读取音频流，不保存任何画面。

## 用法

```bash
BIN=./dist/sysaudio

$BIN --check                                 # 检查权限与运行环境
$BIN --list-apps                             # 列出当前可捕获的应用
$BIN -t 60 -o ~/Desktop/视频原声.wav          # 录制 60 秒，存为 WAV
$BIN -t 30 -o ~/Desktop/原声.mp3             # 按扩展名自动转 MP3（也支持 .m4a）
$BIN -f m4a -o ~/Desktop/原声.m4a            # 一直录，按 Ctrl+C 结束
$BIN --help                                  # 完整参数
```

| 参数 | 说明 |
| --- | --- |
| `-o, --out <路径>` | 输出文件；默认 `~/Desktop/系统录音_<时间戳>.wav` |
| `-t, --seconds <秒>` | 录制时长，`0`（默认）表示直到 Ctrl+C |
| `-f, --format <格式>` | `wav` / `m4a` / `mp3`；未指定时按输出文件扩展名推断 |
| `--keep-wav` | 转码后保留中间的 WAV 文件 |

不带 `-t` 时按 Ctrl+C 优雅停止，程序会正确回填 WAV 文件头再退出。录制期间显示已录时长与文件大小，结束后打印保存路径、时长和格式。

## 输出格式

- **WAV**（默认）：48 kHz / 立体声 / 16-bit PCM，通用性最好
- **M4A**：AAC 192 kbps；**MP3**：libmp3lame VBR Q2（均通过 ffmpeg 转码）

没有声音播放时，系统不会推送音频包，程序会依据时间戳补齐静音，让文件时间轴与真实时间保持一致。

## 实现原理

1. 用 `SCShareableContent` 取得显示器，建立 `SCContentFilter` 与 `SCStream`，开启 `capturesAudio` 并排除本进程音频。
2. 音频回调给出 48 kHz / 双声道 / Float32 非交错的 `CMSampleBuffer`（每包 960 帧），转换成 16-bit 交错 PCM 后写入 WAV。
3. 依据 presentation timestamp 检测包间空隙并补静音；`SIGINT` / `SIGTERM` 触发收尾，回填 RIFF / data 长度字段。
4. 需要 M4A / MP3 时调用 ffmpeg 转码（加了 `-nostdin` 并带超时保护）。

补充说明：Apple 的 Core Audio Process Tap 在本机 macOS 27 上创建成功但 IO 回调始终不触发，故未采用；本机 `swiftc` 工具链存在模块冲突，因此源码使用 Objective-C 而非 Swift。

## 已知限制

- 录制的是系统输出的**全部**声音，暂不支持只挑某一个 App；播放前请先关闭其他声源。
- 权限归属于启动程序的应用（终端或 App），换一种启动方式可能需要重新授权。
- 转码依赖本机 ffmpeg；找不到时会自动回退为 WAV 并给出提示。

## 目录结构

```
MacAudioCapture/
├── main.m          # 程序源码
├── Info.plist      # .app 的包信息与权限用途说明
├── build.sh        # 编译 + 打包 + 签名
├── README.md
└── dist/           # 构建产物（已在 .gitignore 中忽略）
```
