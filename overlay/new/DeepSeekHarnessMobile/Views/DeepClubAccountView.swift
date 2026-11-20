import SwiftUI

struct DeepClubLoginView: View {
    @ObservedObject var account = DeepClubAccount.shared
    var body: some View {
        ZStack {
            Color(red: 244/255, green: 244/255, blue: 245/255).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Image("DeepClubMark").resizable().scaledToFit().frame(width: 76, height: 76)
                    .accessibilityHidden(true)
                Text("DeepClub").font(.system(size: 36, weight: .bold))
                Text("把电脑上的项目，带到手边。")
                    .font(.title2.weight(.medium))
                Text("登录后扫描电脑上的 DeepClub 二维码，继续工作区、会话和审批。文件留在电脑上。")
                    .font(.body).foregroundStyle(.secondary)
                Spacer()
                if let error = account.error { Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("deepclub-login-error") }
                Button { account.login() } label: {
                    HStack(spacing: 12) {
                        if account.busy { ProgressView().tint(.white) }
                        Text(account.busy ? String(localized: "等待浏览器授权…") : String(localized: "使用 DeepClub 登录")).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(.white)
                    .background(DSHColor.ocean, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(account.busy)
                .accessibilityIdentifier("deepclub-browser-login")
                if account.busy { Button("取消登录") { account.cancelLogin() }.frame(maxWidth: .infinity) }
                Text("支持密码、两步验证和 Passkey。仅用于远程连接，不在手机配置模型密钥。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("基于 dsh-mobile · Copyright © 2026 Chaofan Li · MIT")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 14)
            }
            .foregroundStyle(Color(red: 41/255, green: 41/255, blue: 45/255))
            .padding(28).frame(maxWidth: 560)
        }
        .tint(DSHColor.ocean)
    }
}

struct DeepClubAccountView: View {
    @ObservedObject var account = DeepClubAccount.shared
    @State private var confirmsLogout = false
    var body: some View {
        Form {
            Section("DeepClub 账号") {
                LabeledContent("账号", value: account.session?.user.display_name ?? account.session?.user.username ?? "DeepClub")
                if let info = account.bootstrap {
                    LabeledContent("可用余额", value: String(format: "¥%.2f", info.balance))
                    LabeledContent("设备上限", value: "\(info.device_limit)")
                } else { Text("正在读取账号信息…").foregroundStyle(.secondary) }
            }
            Section("登录设备") {
                ForEach(account.devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.device_name.isEmpty ? device.platform : device.device_name)
                        Text(device.is_current ? String(localized: "当前设备") : device.platform).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if account.devices.isEmpty { Text("暂无设备信息").foregroundStyle(.secondary) }
            }
            if let error = account.error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("刷新账号信息") { Task { await account.refresh() } }
                Button("退出登录", role: .destructive) { confirmsLogout = true }
            } footer: { Text("退出将断开全部电脑并清除配对。重新登录后需要重新扫码。") }
        }
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.refresh() }
        .confirmationDialog("退出 DeepClub？", isPresented: $confirmsLogout, titleVisibility: .visible) {
            Button("退出并清除配对", role: .destructive) { Task { await account.logout() } }
        }
    }
}
