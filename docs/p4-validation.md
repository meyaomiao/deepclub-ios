# iOS P4 实际本地联动：Draft 验证记录

角色 Contributor；AI-assisted: OpenAI Codex。Refs [iOS #4](https://github.com/meyaomiao/deepclub-ios/issues/4)、[主集成 #509](https://github.com/meyaomiao/deepclub/issues/509)、[#444](https://github.com/meyaomiao/deepclub/issues/444) / [#480](https://github.com/meyaomiao/deepclub/issues/480)。冻结 P2 [PR #3](https://github.com/meyaomiao/deepclub-ios/pull/3) / `c8f0bd3ee5c25393a5c3f32eb01d38267075446b` 不追加源码；本轮只交付新 P4 分支上的 delta。

本轮已真实通过系统浏览器授权、热进程 OS 深链配对、App 重启恢复和独立 iOS 基本流式任务。Stop、工具 / 原生文件读取、iOS 实际 relay、新二维码冷启动、审批、Host 重启恢复及退出 / 服务端撤销均未完成本轮验收。双端虚拟设备发生系统环境失败后，lead 明确暂停 UI 重试并先提交 Draft 供审查；不能把本记录视为完整 P4 通过。

## 固定本地模式与作用范围

默认 App 构建固定 `https://deepclub.net`；生产 relay 固定 `wss://deepclub.net/ws/mobile/<UUID>`。只有显式 `DEEPCLUB_LOCAL_INTEGRATION` 且同时满足 `DEBUG` 和 `targetEnvironment(simulator)`，账户 origin 才变为 `http://127.0.0.1:18340`、relay 才变为 `ws://127.0.0.1:18340/ws/mobile/<UUID>`。Release 或非模拟器带宏会编译报错；没有运行时地址覆盖、普通用户网关地址或模型 Key 界面。

账户响应校验 scheme / host / 有效端口及无 userinfo，保留禁止重定向的传输。生产 HTTPS/WSS 省略端口与显式 `443` 等价；`0` / `80` / `8443` 拒绝。本地模式省略端口及任何非 `18340` 都拒绝。精确 relay 才接收 `X-DeepClub-Session`；LAN `ws://127.0.0.1:18342/ws/mobile` 不携带手机 session。默认和本地模式的实际源级运行表例见 [安全检查](evidence/p4/safety-results.json) 与 [默认端口检查](evidence/p4/safety-default-ports.json)。

二维码外壳保持 `https://deepclub.net/pair#…` / `deepclub://pair#…`，回调固定 `deepclub://auth/callback`。本轮实际配对使用 OS 自定义 scheme 路由及系统“打开”确认，**不算相机扫码或生产 Universal Link / AASA 已验**。两个 `P4_ROUTE_*` 诊断只在本地编译宏下记录 route 布尔值，不记录 URL、code、用户 ID 或正文；没有修改正常 URL 路由功能。

没有更改 DNS、全局证书、真实 Apple Team、现用 App、用户 profile、既有模型 / 思考 / 权限。不联系上游或提交 Apple。远控账户和连接代码属于产品共享代码，不称为代理 custom-only 改动。

## 结果与证据层级

| 项目 | 本轮结果 | 依据与限制 |
| --- | --- | --- |
| 固定 origin / 精确 relay / LAN 手机 session 隔离 | 通过 | 直接编译并运行产品协议 / parser / 网关源码；生产、本地模拟器与非法宏条件检查 |
| capture / clean prepare / 本轮编译输入 | 通过，1,118 文件，内容与 executable mode 零差异 | [来源记录](evidence/p4/source-provenance.json)；没有复制旧 compiled App / framework |
| KMP 新编译 | 通过，exit 0 / 840.04 秒 | 实际 KSP、compileKotlin、linkDebugFramework 执行；公开依赖缓存只读 / APFS clonefile 复用 |
| Swift App / UI runner | 通过 | 首次磁盘失败保留；续建 exit 0 / 205.82 秒；最终 UI guard 增量构建 exit 0 / 19.33 秒；[构建记录](evidence/p4/build-receipts.json) |
| 系统 ASWebAuthenticationSession → 网页密码登录 / Allow access / callback | 通过，exit 0 / 95.85 秒 | 临时账号 A、实际 Go 网页，无 URLProtocol 或内存账户替代；[授权页](evidence/p4/auth-approve.png) / [原生工作区](evidence/p4/auth-native.png) |
| token / bootstrap → 真实 Keychain；App 重启恢复 | 通过，显式 terminate / launch exit 0 / 56.08 秒 | 无重新登录、无新配对码；[重启截图](evidence/p4/restart-restored.png)；没有导出 Keychain secret |
| 同账号实际 Host pair / hello protocol 3 | 热进程 OS 深链回退通过，exit 0 / 18.8 秒 | [实际 Host / 工作区](evidence/p4/host-connected.png)；[服务端交叉证据](evidence/p4/server-pair-window.json) |
| 项目、会话、基本流式回复 | 通过，独立 iOS `p4-basic` 会话 exit 0 / 70.66 秒 | [原生回复截图](evidence/p4/ios-basic.png) / [服务端持久会话摘要](evidence/p4/server-basic-sessions.json)；真实 Host + Go 代理，本地模型 fixture，无收费模型调用 |
| 长流用户 Stop | **未通过验收** | 首轮未 Send；次轮 fixture 误选 context / title；修复后的实际重验在 runner bootstrap 前被系统终止，从未执行 Stop |
| 工具读 `hello.txt` / 原生文件浏览及预览 | **未执行到该节点** | 联合 scenario 在前置步骤停止，源码存在不算文件读取通过 |
| iOS 实际 relay 业务 | **未执行** | 当前 iOS 实证是 LAN；relay 只有 source / header 安全检查，Android relay 结果不转算 iOS |
| 新二维码冷启动 OS 路由 | **未独立验证** | 先前尝试受系统 Open 确认与测试 activate / relaunch 混杂；热路由成功不推断冷路由通过，也不据此改产品路由 |
| 实际审批 / Host 重启后的手机恢复 | **未验** | 无成功交互证据；主 Host 后来因 fixture 维护重启，但维护后测试没进入 App |
| App 退出 / 服务端撤销后凭据和配对清除 | **未验** | UI driver 有待执行用例，未以源码或 P2 DI 测试替代结果 |
| 专属模拟器清理 | 已 Shutdown，未 delete | 按 lead 待续测指令保留本轮 data / Keychain；没有操作其他模拟器 |

四项实际成功与三次未完成尝试的 method / exit / 耗时和原始 log SHA256 见 [UI 运行回执](evidence/p4/ui-runs.json)；[基本任务 scenario](evidence/p4/scenario-basic.json) 仅包含公开 fixture 动作，不含账户或请求凭据。

服务端不记录 raw hello 帧。protocol 3 的依据是本轮实际 App 接受 hello 并持久化 profile、进入已连接状态时，产品 `GatewayClient` 必须通过 `frame.protocol == 3` 及身份守卫；同时实际返回工作区和会话数据。Go 记录同窗口 assertion / verify 200，Host 明确一个 iOS 设备的两条连接；没有把 `simctl openurl` exit 0 单独当成功。

## 环境、来源和签名

- 专属 `DeepClub4-P4-iPhone`，iPhone 17 Pro / iOS 26.5；UDID `D3D6FA3B-4810-4390-9BF1-C6E81AA0ECA6`。首次新建并完成迁移，P2 已删除的设备没有复用。
- Xcode 26.6 / SDK 26.5，JDK 17，Gradle 9.3.1，Kotlin/Native 2.3.20。Swift / KMP 串行，独立 DerivedData、Gradle、Konan、SwiftPM 路径，只复用公开工具链 / 依赖，不复制私人配置或旧编译产物。
- 固定上游 `f86f005e3491866a2a7aa03f8894dd606a0dde8b`。接手 source 的 Git 是 unborn，capture 正确拒绝；补本地 depth-1 固定 pin 元数据后捕获，没有下载上游历史或修改冻结原树。
- 初始在线依赖解析卡在 HTTP；保留线程 / 日志后取消。离线缺四个 KSP artifact 索引，使用 P2 已验证的 `GRADLE_RO_DEP_CACHE=/Users/xzb/.gradle/caches` 只读入口后，新 KMP 完整编译成功。
- App 签名是模拟器 ad-hoc `CODE_SIGN_IDENTITY=-` / `CODE_SIGN_STYLE=Manual`，Team / provisioning 均为空；[签名记录](evidence/p4/app-signing.txt) 为 `Signature=adhoc`、`TeamIdentifier=not set`，不使用真实证书。
- 最终 overlay source / 本轮编译树 / 新 clean prepare 的 1,118 个输入用仓库 canonical `file_state` 逐项核对；[来源记录](evidence/p4/source-provenance.json) 固定摘要和原树状态。冻结 P2 HEAD 仍为 `c8f0bd3`、git status 空，原 manifest `52efc6d1…` / source-state `f2f737c5…` 与交接完全一致。
- 唯一未编译的 lazy automation-proxy 试探已撤回，交付回到已验证编译输入。task 私有 wrapper 的新增 90 秒 bootstrap watchdog 没有执行过，不混入 App / UI runner 的已验证 whole-source 摘要，也不声称修复系统 kill。

## 安全输入与失败归因

公开 sentinel 实际证明 XCTest 普通 `SecureTextField.typeText` 仍写文本前缀，因此真实密码采用 UI-test-only 固定事件名、`shouldRedact:YES` 的输入 helper。它参考公开 WebDriverAgent 用法，BSD 许可完整保留在 helper 和 NOTICE；没有检查私有二进制，不进入产品 App，不使用 Mac 共享剪贴板。

首个真实登录驱动没确认实际 focus，事件落入用户名字段，自动失败 AX snapshot 含临时密码前缀，未含全文。检测后原始失败资料立即隔离为 600、不读出或上传；lead 用实际 admin API 轮换了仅临时 A 密码，新密码登录成功、旧密码拒绝，已有 session / key / binding 不变。随后加入私密输入前 `Keyboard Focused` 布尔守卫以及用户名不变检查；[公开 focus / redaction 证据](evidence/p4/focused-redaction.json) 38 文件全文 / 前缀零命中，成功授权产物 [1,290 文件扫描](evidence/p4/login-secrecy.json) 亦零命中。这里只提交安全 allowlist 截图 / 摘要，不提交 raw failure AX、有效 QR、private 账户文件或请求正文。

其他未通过的步骤按证据区分：

- 首次 Swift build-for-testing 因 `Mkdtemp … No space left on device (28)` 中断，Xcode / wrapper 结果落盘也失败。释放空间并串行后续建通过，不能归为产品源码错误。
- 网页密码登录真实成功后，系统“保存密码？”sheet 曾遮挡授权页；driver 现在只点“以后 / Not Now”，没有保存测试密码。
- 首次 `openurl` 仅出现系统“在 DeepClub 中打开？”提示；后续实际点 Open 并等待前台、避免测试再次 launch，热路由实际成功。安全 route 标记只有 APP 命中，证伪“只有 Root handler 吞 pair”的猜测；功能路由保持原样。
- 长流首轮冷启动的 authority 请求遭 shared-IP critical bucket 429，未到 verify、未发模型；没有清桶、放宽鉴权、重登录或重新配对绕过。另有位置权限提示被拒绝，本轮不验证后台定位保活。
- 下一轮已 Send，但 fixture 选了最后一条 runtime-context user，主 Agent 实为 634ms / 5-record 普通短回复；约 59.94 秒的另一请求是 title 路径。没有用户 Stop，旧 cancelled+1 不计停止通过。main #509 修复 context 选择和 title gating，13 项 fixture contract 通过后维护 primary Host / model。
- 修复后的实际重验没有进入 TestCase：xcodebuild PID 64928 返回 65；UI runner PID 65248 被 `OS_REASON_RUNNINGBOARD` namespace 15 / `0x2182BAD2` 终止，原因是等待失效 Shared Background Assertion 超时，进程运行 89,365ms。[精确安全摘要](evidence/p4/bootstrap-kill-safe-summary.json) 不推断 OOM。服务端确认新模型进程 requests / active 均为 0。主机同时存在高 system load / swap，另一端也遇系统 ANR，lead 因此暂停更多本机 UI 重试和 task-only 服务。

## 真实 Apple Team 开发签名（2026-11-18）

用户明确授权在付费团队 `3R5RTZSF89` 设置 iPhone 签名。overlay 已含所需授权，本次没有修改 overlay：主 App 的 `Sharing.entitlements` 含 `group.net.deepclub.remote`、`applinks:deepclub.net` 和上游 HealthKit 连接器授权；Share / Action 扩展含同一 App Group；Live Activity 小组件只用 ActivityKit，不读写共享容器，因此不加 App Group。Team 只写入新导出目录中被忽略的 `config/Local.xcconfig`，未提交。

- `scripts/prepare.py` 从固定上游导出新目录，1,118 文件校验通过。首次 `xcodebuild … -configuration Release -destination generic/platform=iOS -allowProvisioningUpdates archive` 已完成 App ID / capability / App Group / profile 注册，但 KMP 阶段因任务离线 Gradle 缓存缺 iosArm64 公开 klib 失败（exit 65 / 390 秒）；在任务自有 Gradle home 联网补齐后 `:shared:linkReleaseFrameworkIosArm64` exit 0 / 442 秒，重跑 archive **ARCHIVE SUCCEEDED**（exit 0 / 910 秒），`codesign --verify --deep --strict` 通过。
- `codesign -d --entitlements :-`：App 与三个扩展 TeamIdentifier 均为 `3R5RTZSF89`；App / Share / Action 的 `com.apple.security.application-groups` 为 `group.net.deepclub.remote`；App 的 `com.apple.developer.associated-domains` 为 `applinks:deepclub.net`。签名身份为团队 Apple Development 证书，`get-task-allow=true`，即开发签名 archive。
- 新建 Xcode 管理 profile：App `5f4b4fe6-d3c6-4ffa-9fa8-77e6a2b60bca`、Share `2d79c4a4-1a9a-4019-bc24-96edbbbbf894`、Action `1884c434-b895-4f1c-95df-17f1b33c362b`，均至 2027-11-18；小组件使用既有团队通配开发 profile `199e5ecc-…`（至 2027-09-20）。详见 [签名证据](evidence/p4/ios-signing.json)，不含证书私钥或账户凭据。
- 只读检查：`https://deepclub.net/.well-known/apple-app-site-association` 返回 SPA HTML，Apple CDN 返回 404，生产 AASA 尚未部署；配对 iPhone 17 仍为 `unavailable`，没有安装。

未做：App Store 分发签名 / 导出、App Store Connect App 记录、TestFlight 上传、真机安装与验收、AASA 部署及 Universal Link 验证。

## 自动化检查与后续

本仓当前没有本地 `.github/workflows`；[GitHub Actions 查询](evidence/p4/repository-workflows.json) 记录实际可用的 workflow 数量。没有把未运行的远端 CI、主仓契约测试或冻结 P2 的 20 项 DI / Keychain 单测转算为本轮 iOS UI 通过。Draft 的人工确认保持未勾选，不 Ready / merge，不使用 `Closes` 自动关闭执行单。

恢复环境后应重新协调 shared-IP CT slot 与独占模型 / QR 窗口，先验证真正长流 `P4 stream …` 后再实际点 Stop，按新 request-mode ring 和持久 turn reason 交叉证明；随后工具读取、原生文件预览、iOS relay-first QR、冷 OS 新 QR、审批和单设备撤销分别取证。保留现有测试账户 / 配对状态继续，不能用重复登录或清桶掩盖问题。

除上节真实 Team 开发签名 archive 外，没有真机、跨公网、分发签名、AASA、App Store / TestFlight、生产部署或收费模型证据。保留 dsh-mobile / Whaleness、Chaofan Li MIT 与所有依赖许可及 protectedNewAPI / QuantumNous 来源署名。
