# iOS 版 —— 不用 Mac 也能装（完整方案）

> 全程在一台 **Windows 电脑 + 一部 iPhone** 上完成，**不需要 Mac、不需要 Mac 虚拟机、不需要云 Mac 付费**。

---

## 方案原理

```
┌─────────────────────┐        ┌──────────────────────────┐
│  ① 云端编译（免费）  │        │  ② 本地签名安装（免费）    │
│  GitHub Actions     │  ipa   │  Sideloadly (Windows)    │
│  的 macOS runner     │ ─────► │  用你的 Apple ID 签名     │
│  xcodebuild 无签名   │  下载   │  通过 USB 装进 iPhone     │
└─────────────────────┘        └──────────────────────────┘
                                                        ↓
                                              iPhone 设置里信任证书
```

**为什么可行**：
- GitHub 给**免费**的 macOS runner（每次最多 6 小时）—— 这就解决了「没有 Mac」的问题
- 编译时用 `CODE_SIGNING_ALLOWED=NO` 产出**未签名 ipa**
- **Sideloadly** 在 Windows 上用你的 Apple ID 完成签名并安装（免费账号 7 天有效）

---

## 准备工作（一次性，约 10 分钟）

| 需要 | 说明 |
|---|---|
| **GitHub 账号** | 免费注册 → https://github.com/signup |
| **Sideloadly** | Windows 版 → https://sideloadly.io |
| **iTunes**（或 Apple 设备驱动） | Sideloadly 需要它来与 iPhone 通信（也可装 Microsoft Store 版「Apple 设备」） |
| **Apple ID** | 就是你的 iPhone 账号，普通免费账号即可 |

---

## 第 ① 步：云端编译出 ipa

### 1.1 创建仓库

1. 登录 GitHub → 右上角 **+** → **New repository**
2. 名称随意，例如 `ios-water-tool`
3. 选 **Private**（私有，别人看不到）或 Public 都行
4. **Create repository**

### 1.2 上传本工程

把 `QzxyTamper-iOS-控额版.zip` 解压后，**把这些都传上去**：

```
├── QzxyTamper/                 ← 5 个 .swift + Info.plist
│   ├── QzxyCrypto.swift
│   ├── BleFrameCodec.swift
│   ├── KlcxkjBleCentral.swift
│   ├── TamperEngine.swift
│   ├── TamperView.swift
│   └── Info.plist
├── .github/workflows/build-ios.yml   ← ★ 自动编译脚本（关键）
├── project.yml                  ← ★ XcodeGen 工程描述（关键）
└── README.md
```

**上传方式**（Web 界面最简单）：
1. 仓库页面 → **Add file** → **Upload files**
2. 把文件夹**拖进去**
3. ⚠️ **注意 `.github` 目录是隐藏文件夹** —— 用下面的「命令行方式」更可靠
4. **Commit changes**

**命令行方式**（推荐，能带上隐藏目录）：
```bash
cd QzxyTamper-iOS-控额版
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/你的用户名/ios-water-tool.git
git push -u origin main
```

### 1.3 等编译完成

1. 打开仓库 → **Actions** 标签页
2. 会看到 **Build iOS IPA (no Mac needed)** 正在跑（黄色圆点）
3. 等 3~6 分钟 → 变成 **绿色勾** ✅
4. 点进这一次运行 → 页面底部 **Artifacts** → 下载 **QzxyTamper-ipa**（是个 zip）
5. 解压得到 **`QzxyTamper-unsigned.ipa`**

> **如果显示红色 ✗**：点进去看日志，把报错发我，我改。

---

## 第 ② 步：用 Sideloadly 装到 iPhone

### 2.1 安装 Sideloadly

1. 去 https://sideloadly.io 下载 Windows 版
2. 安装（同时确保已装 iTunes 或 Microsoft Store 的「Apple 设备」）

### 2.2 连接 iPhone

1. 数据线连上电脑
2. iPhone 上点 **信任此电脑**
3. 打开 Sideloadly，左上角 **iDevice** 应能识别到你的手机

### 2.3 签名安装

```
IPA 文件      →  选刚下载的 QzxyTamper-unsigned.ipa
Apple ID      →  填你的 Apple ID
（密码会提示输入，用于向 Apple 换取免费签名证书）

点 [Start]
```

等 1~2 分钟，看到 **Done** 就好了。

### 2.4 信任证书（必做，否则打不开）

iPhone 上：
```
设置 → 通用 → VPN与设备管理 → 开发者App
  → 找到你的 Apple ID
  → 点「信任」
```

然后回桌面就能打开 **水表工具** 了。

---

## 第 ③ 步：使用

```
① 登录            手机号 + 密码
② 扫描蓝牙        找 KLCXKJ-Water → 点一下自动填 SN
                  （或直接手输机身标签上的 12 位 SN）
                  界面会显示「推导 MAC = C4:7F:0E:...」
③ 勾「启用控额」   固定 ¥0.06  或  区间 ¥0.10~¥0.50
④ 点「★ 一键」     开阀 → 用水 → 关阀（按目标金额记账）→ 清记录
```

日志里核对 `结算金额 upMoney=60`（对应你设的 ¥0.06）。

---

## ⚠️ 三个必须知道的限制

| 限制 | 说明 | 对策 |
|---|---|---|
| **7 天有效期** | 免费 Apple ID 签的 App 7 天后打不开 | 到期后用 Sideloadly 重新点一次 Start 即可（ipa 留着）；或开 Sideloadly 的「自动续签」 |
| **同时最多 3 个自签 App** | Apple 的限制 | 不需要时删掉别的自签 App |
| **依赖电脑续签** | 每次续签要插线 | 想彻底摆脱可用 **AltStore**（同一 WiFi 下自动续签，服务器装在电脑上） |

---

## 备选方案（如果不想用 GitHub）

| 平台 | 免费额度 | 说明 |
|---|---|---|
| **Codemagic** | 每月 500 分钟 macOS | https://codemagic.io —— 配置比 Actions 简单些，界面化 |
| **AppCircle** | 有免费层 | https://appcircle.io |
| **Expo EAS Build** | 有免费层 | 主要面向 React Native，原生工程不适用 |
| **云 Mac 租用** | 付费 | MacinCloud / MacStadium，按小时 |

**推荐还是 GitHub Actions**：完全免费、额度充足、可反复触发。

---

## 排查

| 现象 | 处理 |
|---|---|
| Actions 里找不到 workflow | `.github` 目录没传上去（隐藏目录）→ 用命令行 `git push` |
| 编译报错 `scheme not found` | XcodeGen 没生效 → 检查 `project.yml` 是否在根目录 |
| 编译报错其它 | 把 Actions 日志发我 |
| Sideloadly 提示 `Provision failed` | Apple ID 有问题（需先在 iPhone 上登录 App Store） |
| 装完打不开 App | 忘了「信任证书」→ 设置里信任 |
| 7 天后图标变灰 | 正常，用 Sideloadly 重签一次 |

---

## 一句话总结

```
注册 GitHub（免费）
  → 拖文件上去 → 等 5 分钟 → 下载 ipa
  → Sideloadly 输 Apple ID → 装进手机 → 信任证书
  → 完事
```

**全程 0 成本、0 Mac。**
