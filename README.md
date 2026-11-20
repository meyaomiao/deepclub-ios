# DeepClub iOS

DeepClub iOS 基于成熟的 dsh-mobile / Whaleness（SwiftUI + Kotlin Multiplatform），用于登录 DeepClub 账号后连接自己的电脑。电脑上的项目、已有会话、文件与审批界面继续使用原有实现；文件与 Agent 执行留在电脑上。iOS 只申请 `ios_remote` 设备会话，不申请或展示模型 API Key，不提供普通用户手工 SSH、网关地址或模型 Key 配置入口。

本仓是独立改造层，不复制上游 Git 历史。执行单为 [#2](https://github.com/meyaomiao/deepclub-ios/issues/2)，承接 [#1](https://github.com/meyaomiao/deepclub-ios/issues/1)、[移动端总方案 #444](https://github.com/meyaomiao/deepclub/issues/444) 与 [统一配对契约 #480](https://github.com/meyaomiao/deepclub/issues/480)。角色 Contributor；AI-assisted: OpenAI Codex。

## 源码与重建

[upstream.lock.json](upstream.lock.json) 固定 dsh-mobile `f86f005e3491866a2a7aa03f8894dd606a0dde8b`；整合基于本仓 main `6ec0f8462361347cfd0d4a443acb200f4942e408`。实际 Swift、Kotlin、Xcode 工程、扩展、品牌和 XCTest 修改进入 [overlay](overlay/manifest.json)，并非仅品牌脚本或设计文档。

需要本地已有的固定上游 checkout（脚本不联网取源码，也不修改输入）：

```sh
python3 scripts/prepare.py --upstream-checkout /path/to/pinned-dsh-mobile --output /path/to/new-DeepClub-source
```

脚本校验固定 HEAD、上游逐文件 SHA256、overlay 逐文件 SHA256、patch 文件列表，再按 allowlist 导出 iOS 工程。输出必须是新目录；最后逐项验证文件列表、内容摘要和 executable mode，任何多余私密配置/缓存文件都导致失败。导出排除 Android 工程、嵌入 Go/Tsnet、构建产物、缓存、私钥、provisioning、Local.xcconfig 与用户 Xcode 状态。

继续开发时，使用**自己隔离的**固定 upstream checkout 修改，先等待所有写入结束，再捕获：

```sh
python3 scripts/capture-overlay.py --checkout /path/to/your-isolated-prepared
# 已有 overlay 经审查更新时才加 --refresh
python3 scripts/prepare.py --upstream-checkout /path/to/your-isolated-prepared --output /path/to/new-clean-rebuild
```

[capture-overlay.py](scripts/capture-overlay.py) 在读取前后比对导出状态与 HEAD，拒绝移动中的源。文本差异、完整新文件、替换资产与移除记录分别保存；manifest 固定所有交付输入。品牌由 [symbol-color.svg](brand/symbol-color.svg) 与 [render-brand.py](scripts/render-brand.py) 维护。许可证见 [LICENSE.upstream](LICENSE.upstream)、[NOTICE](NOTICE) 及 App 内第三方许可。

## 登录与配对

系统 `ASWebAuthenticationSession` 使用 S256 PKCE、随机 state 和固定回调 `deepclub://auth/callback`。token/bootstrap 完成账号与 `ios_remote` 校验后才写 Keychain；token 响应包含 `api_key` 或 `token_id` 会被拒绝。退出、撤销、失效清除会话及所有电脑配对并断开连接。账户余额只读。

外部 `deepclub://pair#…` 或 `https://deepclub.net/pair#…` 在未登录时，仅在进程内存保存已验证的配对意图；不会把 raw URL、pairingCode 存入 UserDefaults 或日志。登录前的凭据清理保留本次意图；浏览器授权成功后重新校验过期并只消费一次。取消、失败、退出清除；已消费 code 的哈希在有效期内防重复回调或相同 code 重编码重放。auth callback 仅由系统浏览器授权路径处理，不能进入配对解析。

统一二维码要求 version 2、`dsh-mobile-v1`、短效 code、UUID 网关与公开 `sha256:` 加 64 位小写十六进制 hostKey。候选仅允许本地电脑地址或精确 DeepClub relay，不把载荷当任意 URL 打开。电脑配对/连接使用同账号短效断言和身份钉扎；hello 保留 protocol 3。手机 session 只发 `wss://deepclub.net/ws/mobile/<gatewayID>` 精确端点，LAN 不携带手机 session。远控连接服务属于产品共享代码，并非代理 custom preset 私有改动。

## 构建和验证

需要 Xcode、iOS Simulator SDK、JDK 17、Gradle wrapper 和 Kotlin/Native。先串行构建 KMP，再用独立 DerivedData 构建 Swift：

```sh
cd /path/to/new-clean-rebuild
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export GRADLE_USER_HOME=/path/to/own-gradle-cache
export KONAN_DATA_DIR=/path/to/own-konan-cache
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64 --no-daemon --console=plain
xcodebuild -project DeepSeekHarnessMobile.xcodeproj -scheme DeepSeekHarnessMobile \
  -onlyUsePackageVersionsFromResolvedFile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /path/to/own-DerivedData CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM= LOCAL_DEVELOPMENT_TEAM= build
```

测试必须指定自己新建的 simulator UDID，不操作已有模拟器或用户 App。完整测试包含真实系统 Keychain 的临时条目往返，需要下面的**仅模拟器 ad-hoc 签名**；`-` 表示本地签名，不使用证书、Apple Team 或 provisioning，不代表真机/分发签名：

```sh
xcodebuild -project DeepSeekHarnessMobile.xcodeproj -scheme DeepSeekHarnessMobile \
  -onlyUsePackageVersionsFromResolvedFile -sdk iphonesimulator -destination 'platform=iOS Simulator,id=<own-new-UDID>' \
  -derivedDataPath /path/to/own-DerivedData CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= LOCAL_DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE= -parallel-testing-enabled NO \
  -only-testing:DeepSeekHarnessMobileTests/DeepClubProtocolTests \
  -only-testing:DeepSeekHarnessMobileTests/DeepClubAccountTests \
  -only-testing:DeepSeekHarnessMobileTests/DeepClubDeepLinkTests test
```

本轮保留禁签名 build/19 项合成测试的通过证据；禁签名包的真实 Keychain 返回 `errSecMissingEntitlement (-34018)`，不能用注入测试冒充实际存储可用。上述 ad-hoc 命令已经实际 build/test 通过 20 项：19 项逻辑测试继续通过，新增系统 Keychain 临时条目 save/load/delete 验证及 fresh 无凭据错误检查通过，探针条目随即删除。DeepClub 逻辑测试通过依赖注入和 URLProtocol 合成浏览器授权、token/bootstrap 响应、深链意图和 LAN/relay header，不使用真实账号或收费模型。具体本轮结果、工具链、源指纹和未验边界见 [验证记录](docs/validation.md)。模拟器、合成协议测试不能代表真实账户端到端、真机、跨网、正式签名、AASA、App Store 或 TestFlight 已验。

保留 dsh-mobile / Whaleness、Chaofan Li 的 MIT 版权及依赖许可。DeepClub 账号服务的 protectedNewAPI / QuantumNous 来源署名保留在 NOTICE；本导出没有复制其服务端代码。本产品不是 DeepSeek 官方产品，不联系上游作者，不提交 Apple 或生产发布。
