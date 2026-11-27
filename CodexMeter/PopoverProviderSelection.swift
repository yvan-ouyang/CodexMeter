// 下拉框供应商选择状态；真实打开和设置变更由 StatusBarController 驱动，不在 SwiftUI 渲染时重置或读取数据。
import Combine

/// 下拉框的稳定页选择器。可见性只由宿主传入的显示偏好确定，切换本身不访问任何供应商。
@MainActor
final class PopoverProviderSelection: ObservableObject {
    enum Provider: String, Identifiable, Sendable {
        case antigravity, codex, openCodeGo
        var id: String { rawValue }

        /// 页签文本采用供应商品牌名称，保持窄弹窗和不同语言下的稳定顺序。
        var title: String {
            switch self {
            case .antigravity: return "Antigravity"
            case .codex: return "Codex"
            case .openCodeGo: return "OpenCode Go"
            }
        }
    }

    @Published private(set) var tabs: [Provider] = [.codex]
    @Published private(set) var selected: Provider = .codex

    /// 仅在真实弹窗从关闭到打开时调用：优先 Antigravity，否则选择始终可用的 Codex。
    func open(antigravityVisible: Bool, goVisible: Bool) {
        reconcile(antigravityVisible: antigravityVisible, goVisible: goVisible)
        select(tabs[0])
    }

    /// 设置变化只移除已不可见的选择；不因启用其他供应商或宿主重建而抢占合法页。
    func reconcile(antigravityVisible: Bool, goVisible: Bool) {
        var visible: [Provider] = []
        if antigravityVisible { visible.append(.antigravity) }
        visible.append(.codex)
        if goVisible { visible.append(.openCodeGo) }
        if tabs != visible { tabs = visible }
        if !visible.contains(selected) { select(visible[0]) }
    }

    /// 只接受当前合法的页；隐藏页的延迟控件事件不应改变选择。
    func select(_ provider: Provider) {
        guard tabs.contains(provider), selected != provider else { return }
        selected = provider
    }
}
