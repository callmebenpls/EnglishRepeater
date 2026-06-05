# 英语复读机 — English Repeater

一款专为英语学习设计的 iOS 播放器，支持通过苹果耳机一键复读前 5 秒或 10 秒。

---

## 功能

- **本地音频导入**：支持 mp3、m4a、aac、wav 等格式
- **一键复读**：回退 5 秒或 10 秒并自动继续播放
- **耳机控制**：通过苹果耳机中键（单击 / 双击 / 三击）控制复读
- **自定义按键映射**：在设置页自由配置每种点击的动作
- **后台播放**：锁屏 / 后台状态下持续播放，耳机按键仍有效
- **锁屏控制中心**：Now Playing 元数据同步，进度条可拖动

---

## 使用方法

1. 点击左上角文件夹图标，从「文件」App 导入音频
2. 播放器自动开始播放
3. 点击「前 5 秒」或「前 10 秒」按钮复读
4. 右上角进入设置，配置耳机按键映射
5. 耳机中键按键在锁屏和后台均可触发复读

---

## 耳机按键说明

| 耳机类型 | 单击 | 双击 | 三击 |
|---------|------|------|------|
| AirPods | 播放/暂停 | 下一首（可映射） | 上一首（可映射） |
| 有线耳机 | 播放/暂停 | 音量+ | 音量- |

> 提示：AirPods 双击默认映射到 `nextTrackCommand`，三击映射到 `previousTrackCommand`。可在 AirPods 蓝牙设置中改为「上/下一首」，然后在本 App 设置中将对应动作改为复读。

---

## 开发环境

- Xcode 15+
- iOS 16+
- Swift 5.9
- 无第三方依赖

## 运行步骤

1. 打开 `EnglishRepeater.xcodeproj`
2. 修改 Bundle Identifier（`com.yourname.EnglishRepeater` → 你的 ID）
3. 选择真机（模拟器无法测试耳机按键）
4. Build & Run

---

## 文件结构

```
EnglishRepeater/
├── EnglishRepeaterApp.swift   # App 入口
├── ContentView.swift          # 主界面
├── PlayerViewModel.swift      # 播放逻辑 + 耳机按键绑定
├── SettingsView.swift         # 按键映射设置
└── Info.plist                 # 后台音频权限配置
```
