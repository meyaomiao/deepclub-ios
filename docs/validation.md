# iOS P2 整合验证记录

角色 Contributor；执行单 [deepclub-ios#2](https://github.com/meyaomiao/deepclub-ios/issues/2)。本轮由实际 Swift/KMP 源码生成 overlay 并从固定上游重建，没有复制旧 build framework，也没有用旧日志代替本次构建。

## 来源与隔离

- adaptation main：`6ec0f8462361347cfd0d4a443acb200f4942e408`。
- upstream / 原 source HEAD：`f86f005e3491866a2a7aa03f8894dd606a0dde8b`。
- 原源 tracked 差异 48 个；`git diff --binary HEAD` 为 2,281,589 字节，SHA256 `9f70d2a4046a4d7509b18d0e0a5262a6218bab26b4eec0036c0ed76b008033b6`，与交接快照一致。
- 原源未跟踪文件按路径字节排序并连接路径/内容（忽略 .DS_Store）：SHA256 `218e4758e373c9622de1c8623c5b066908f2a8cc8881d498d7688dc5042e8d26`，与交接一致。
- allowlist 导出 1,114 个原始 iOS 文件，读取复制前后 `source-state` JSON 的 SHA256 均为 `887c2ed6d840ea799a7568dba959532e138be9f881e83417672a37026b4fb8da`；不包含私密配置、缓存、签名、作者 Team 或 Android 工程。
- 新增深链测试后导出 1,115 个文件；49 个文本修改、13 个新文件、3 个替换资产、4 个删除项。manifest 逐文件记录摘要与模式。保留原有成熟业务源码与许可，并补充实际解析的 ChatLayout、NetworkImage、swift-cmark 原文许可证。
- 首次 prepare 实际发现并修复：工程 patch 尾随空白；同目录多文件删除导致重复清理空目录。修复后 clean prepare 完整验证文件集合、内容和模式一致。
- 首轮实际 Xcode build 因缺少独立 Metal Toolchain 失败（exit 65），日志另存 `attempt1-xcode-build.log`。完整 Swift 引用搜索仅发现未被调用的 private `HarnessFluidLayer` 使用 Metal；当前 DeepClub 背景只调用 SwiftUI 渐变和品牌图标。因此只移除该闲置 helper 和 Metal build phase；保留 shader 源码、原 script 与成熟业务 UI，不安装或修改系统工具链。
- SwiftPM 自动解析曾把 upstream lock 的 cmark 0.8.0 浮动到 0.9.0；最终固定公开 Vendor 依赖到原 lock 版本 cmark 0.8.0 / NetworkImage 6.0.1，避免顺带升级，严格按 resolved 版本构建。
- 实际编译还定位并修复此前未验源码：SDK 未提供的未来 toolbar API 加编译保护并保留当前布局；后台任务使用当前公开 `submit(_:)`；账户退出错误提示使用 `self.error` 避免 catch 变量遮蔽。原 scheme 同时编译的 UI 采样测试两处 `XCUIApplication.open` 加 iOS 16.4 guard；没有执行该真实会话采样测试。原单测 bundle 的 UIKit layout fixtures 使用 iOS 17 的 trait API，因此只将单测 bundle 的最低系统对齐到 17.0；App 和扩展仍保持 16.1，实际运行选用 26.5，并未删去或跳过原测试源码。
- 普通设置移除手工 ws 网关地址、端口和 Ping；只保留已配对电脑连接、状态与诊断。未配对连接按钮禁用。未登录 restoreProfiles、缺少设备凭据的冷启动恢复、缺少 gatewayID/hostKey 的传输准备与无 session 的 assertion 请求均有守卫；新增测试验证默认 localhost 不会创建匿名 socket 或连接准备任务。

实现与构建只写独立目录 `/Users/xzb/Documents/_issue-worktrees/deepclub-ios-p2-integration` 及其专属 `.work/prepared`、重建目录、`.work/DerivedData`、`.work/gradle`、`.work/konan`、`.work/SourcePackages` 与专属模拟器。初始核对曾对原 adaptation 执行一次 `git fetch origin main`，更新其 Git 远端元数据；原工作树内容与原 source 没有修改，后续不再向原目录写入。未操作用户已有模拟器、App、profile、模型或 60702 GUI。最终干净导出与同一任务编译树按 manifest 逐项核对输入，只复用本轮隔离构建产生的缓存。

## 工具链与实际执行

- Xcode 26.6 / build 17F113；iOS Simulator SDK 26.5。
- JDK 17.0.20.1、Gradle 9.3.1、Kotlin/Native 2.3.20。任务独立 Gradle/Konan 缓存；仅只读复用已安装公开工具链与公开依赖，未复制原 source/build 缓存。
- KMP：在本轮 clean rebuild 上执行 `:shared:linkDebugFrameworkIosSimulatorArm64`，**BUILD SUCCESSFUL in 3m 49s**，5 actionable tasks / 5 executed。完整本地日志 `.work/evidence/kmp-final.log`；只有已有 expect/actual beta 警告。
- 新建模拟器：`DeepClub2-P2-iPhone`，iPhone 17 Pro，iOS 26.5，UDID `C219BB5D-F375-4569-84C1-D4B2D4EEBF84`。首次启动迁移完成，不复用或操作其他设备。
- 首次完整禁签名验证：build exit0（34.32s），19 项逻辑测试 exit0（49.00s），0 failures/0 skips，保留 [禁签名命令](evidence/unsigned19-xcode-results.json) 与 [原测试摘要](evidence/unsigned19-xcresult-summary.json)。
- 随后对同一任务模拟器做精确系统 Keychain 诊断：禁签名包的 `SecItemCopyMatching` 与 `SecItemDelete` 均返回 **-34018 / errSecMissingEntitlement**，并非 missing-item 处理错误。`errSecItemNotFound (-25300)` 的 load→nil、delete→成功逻辑原本正确。
- 按追加授权使用**仅模拟器、无证书/无 Team 的完整 ad-hoc 签名**后：build **exit0 / BUILD SUCCEEDED**（102.97s），test **exit0 / TEST SUCCEEDED**（98.37s）。实际执行 **20 tests / 0 failures / 0 skips**：Account 4（含真实系统 Keychain probe）、Protocol 6、DeepLink/fresh 10；方法运行时间 1.310s。真实 probe 的 missing lookup/delete 均为 -25300，实际 save/load/delete 往返和清理成功，fresh account 的 session=nil/error=nil 断言通过。
- 最终 clean prepare 及编译后再次核对全部 1,115 个输入文件，内容/模式与 source-state 完全一致；source-state SHA256 `f2f737c5ee08ad02000c9596511a35b8c9c5211287b96d3fbdfb5fc9bad27f29`。原 source 最终 tracked/untracked 指纹仍与交接相同。参见 [来源及产物摘要](evidence/provenance.json)、[实际命令与退出码](evidence/xcode-results.json)、[xcresult 摘要](evidence/xcresult-summary.json)、[测试日志](evidence/deepclub-tests.log)、[本轮首次 KMP 完整编译日志](evidence/kmp-simulator.log)。
- 专属模拟器已先 **Shutdown**，再按精确 UDID **delete**；设备注册记录不存在，已核验的绝对设备数据目录已删除，其他既有 simulator ID 均保留。参见 [精确清理记录](evidence/simulator-cleanup.json)。
- 初始禁签名使用 `CODE_SIGNING_ALLOWED=NO`；最终 ad-hoc 使用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`，DevelopmentTeam/LocalTeam/provisioning 全为空，签名显示 `Sign to Run Locally` / `TeamIdentifier=not set`，不使用真实证书。Xcode 自动生成的模拟器 application-id 前缀仅记入 [签名诊断](evidence/keychain-signing.json)，没有写入源码或 Team 配置。
- Xcode 命令均使用独立 DerivedData、arm64 simulator，测试关闭并行并指定上述 UDID。stdout/退出码持续写 `.work/evidence/adhoc-xcode-build.log`、`adhoc-xcode-test.log`、`adhoc-xcode-runner.log`、`adhoc-xcode-results.json`；禁签名失败对照和先前19项通过日志另存。当前仓库没有自动CI workflow，以上均为本地实际执行证据。

## 自动化测试范围

既有 `DeepClubProtocolTests` 覆盖 S256、client_type、state/回调来源/重复参数、一次性 callback、token 响应拒绝模型 Key、统一 QR 及过期、精确 relay 与 LAN session 隔离。既有 `DeepClubAccountTests` 覆盖退出与异步设备凭据写入的互斥和取消隔离。

新增 `DeepClubDeepLinkTests` 通过注入浏览器、临时 UserDefaults、内存凭据和 URLProtocol，执行实际账户实现的 state/PKCE → token → bootstrap → 完成授权路径；不会调真实账户、生产授权或模型。验证自定义 scheme 与 Universal Link 未登录暂存、成功后一次消费、授权期间/完成后重复回调、浏览器取消/失败、显式取消后的迟到成功、错误 state、授权期间二维码过期、未知链接与 auth callback 分离、任意公网 QR 候选拒绝、重编码重放及配对失败后不再消费、退出清空等待意图。fresh store 用例实际发现并回归：清理连接时不能继续复用已停用、业务回调和扫码 handler 均已被清空的初始容器；现在在需要时重建完整未配对容器，并确认重复清理仍保留安全扫码导入入口。

## 未验边界

未运行真实账号与 desktop#43 / backend#501 的完整配对、同 Wi-Fi/跨公网、不同账号拒绝、服务端撤销即断、真实项目/会话/文件/审批端到端。以上能力保留成熟 UI/协议和合成测试；源码存在、单元测试或编译成功不代表端到端通过。

独立手动启动实际 App（没有点击登录）的对照：先前 [禁签名截图](evidence/simulator-startup-unsigned.png) 显示安全凭据清理错误；完整 simulator ad-hoc 后的 [fresh 启动截图](evidence/simulator-startup-adhoc.png) 不再出现该错误，DeepClub 登录按钮和 MIT 署名保留，正常 OS 通知授权框如实保留。实际系统 Keychain 临时条目往返已验；浏览器授权和 token/bootstrap 仍为合成注入，**不能视为真实账号 ASWebAuthenticationSession 登录已通过**。没有绕过 Keychain、改存 UserDefaults 或设置虚假/作者 Team。

未使用真机、真实 Apple Team/证书、真机或分发签名/provisioning；未配置/伪造 AASA；未提交 App Store、TestFlight、收费模型或生产部署。Universal Link 解析可合成验证，iOS 系统从生产域名派发 Universal Link 仍依赖未来正式 entitlement/AASA 验收。

电脑连接是产品级共享服务，不是 custom-only 代理预设改动。保留 MIT/Whaleness/Chaofan Li、依赖许可及 protectedNewAPI / QuantumNous 账号服务来源署名。
