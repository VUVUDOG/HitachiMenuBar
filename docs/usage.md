# 安装与使用

[下载最新版](https://github.com/VUVUDOG/HitachiMenuBar/releases/latest)。本说明和截图对应 **v0.3.4**。

[PDF 图文指南](https://github.com/VUVUDOG/HitachiMenuBar/releases/download/v0.3.4/HitachiMenuBar-0.3.4-guide.pdf) · [离线网页版](https://github.com/VUVUDOG/HitachiMenuBar/releases/download/v0.3.4/HitachiMenuBar-0.3.4-guide.html) · [长图](https://github.com/VUVUDOG/HitachiMenuBar/releases/download/v0.3.4/HitachiMenuBar-0.3.4-guide.png) · [含两种安装包的分享包](https://github.com/VUVUDOG/HitachiMenuBar/releases/download/v0.3.4/HitachiMenuBar-0.3.4-sharing-kit.zip)

## 1. 手机关联设备

米家 → 连接三方平台 → 日立中央空调 → 输入日立智家账号密码 → 完成关联。确认手机米家能控制设备。已关联用户可跳过。

## 2. 安装

 → 关于本机：M 系列选择 `arm64.zip`，Intel 选择 `intel.zip`。要求 macOS 13+。

解压，将 `HitachiMenuBar.app` 放入应用程序并打开。当前未公证，若系统提示无法验证开发者，确认来源后在「系统设置 → 隐私与安全性」选择「仍要打开」。

## 3. 扫码登录

<img src="images/login-glass.png" alt="v0.3.4 玻璃底色的扫码登录入口" width="360">

点击菜单栏「空调」→「扫码登录米家」，用已关联设备的米家账号扫描软件实时二维码并在手机确认。过期时重新发起扫码。每台 Mac 独立登录。

## 4. 控制面板

<img src="images/control-glass.png" alt="v0.3.4 Liquid Glass 控制面板，演示数据" width="360">

| 位置 | 用法 |
| --- | --- |
| 房间卡片 | 切换房间，绿色圆点代表开启；切换本身不会控制设备。 |
| 电源 | 开关当前房间，等待回读确认。 |
| 大数字、− / +、滑块 | 显示及调整设定温度；滑块松开后发送设置。 |
| 模式、风量 | 选择设备支持的选项，绿色表示选中。 |
| 右下角刷新 | 手动获取最新状态。 |
| 齿轮 | 同步房间、重新登录、退出登录、版本、复制诊断、退出应用。 |

展开立即刷新，随后每 30 秒自动刷新；收起暂停。忙碌时跳过重复刷新，授权失败后暂停自动重试。点击面板外或按 Esc 收起。

当前已验证设备没有实测室温属性，大数字是设定温度。功能及范围依设备而定。

v0.3.4 主面板具有系统玻璃底色和阴影：macOS 26+ 使用原生 Liquid Glass，macOS 13–15 使用系统菜单毛玻璃。底色随壁纸和后方窗口变化，具体透明程度由系统材质及辅助功能设置决定。外观按系统版本选择，与 Mac 芯片类型无关。

以上截图使用 v0.3.4 的原生视图，在 macOS 26 上渲染；房间、状态和桌面背景为演示数据。

## 5. 钥匙串与账号

- 输入当前 Mac 的「登录」钥匙串密码，通常与本机登录密码相同。
- 确认为本软件请求后，「始终允许」记住授权；「允许」仅限本次。
- 退出应用保留凭证；退出登录清除凭证和房间缓存。
- 重新登录立即作废旧会话，取消扫码不会恢复旧账号。
- 开发签名更新可能重新申请授权。重复弹窗仍是已知问题；有登录态不代表系统已永久允许读取。

## 6. 排查与更新

没有房间时检查米家账号和手机设备列表，再「同步房间」。状态异常时看底部提示，检查设备在线并手动刷新。提示登录失效后重新扫码；钥匙串权限问题先完成授权。

更新前从齿轮退出应用，再替换旧版本。有效会话通常保留，新版本可能需要重新钥匙串授权。

反馈时提供版本、Mac 芯片、macOS 版本、步骤和诊断信息。
