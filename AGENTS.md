# DeepClub iOS 改造层

本仓库执行 meyaomiao/deepclub#444 P2；首版总单 meyaomiao/deepclub-ios#1，本轮独立整合执行单 meyaomiao/deepclub-ios#2。仅在 owner 分支修改，不联系上游，不部署或提交 Apple。保留 dsh-mobile 的 MIT / Chaofan Li 版权和所有依赖许可。

上游固定为 upstream.lock.json；在隔离 source checkout 实现，经 scripts/capture-overlay.py 捕获文本 patch、新文件、资产及 SHA256，再用 scripts/prepare.py 验证重建。不得整拷上游历史，不引入 Android 工程到 iOS 产品。不改 DSH-abilities。

应用名 DeepClub，Bundle net.deepclub.remote（包含扩展和 AppGroup）。iOS 只远程：系统浏览器 S256 PKCE、Keychain 设备 session，同账号断言与主机指纹钉扎。手机 session 仅发 DeepClub，电脑只能收到短效断言与其自行签发的设备凭据。退出、撤销与新授权清除旧配对并停止连接。不得申领模型 Key，不改用户已有模型/思考/权限。关闭原作者推送、统计、更新下载和社区外联。

Swift/KMP 构建串行，使用独立 DerivedData 和每次新建的专属模拟器，记录名称及 UDID（本轮 DeepClub2-P2-iPhone）。不操作或关闭已有模拟器。证据区分单元、合成、模拟器、真机和生产；未执行不得标为通过。Draft 材料准备后交 lead review 再提交。
