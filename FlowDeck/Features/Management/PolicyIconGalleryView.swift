import SwiftUI

/// 内置图标目录用于核对覆盖范围，与策略列表共用真实资产与解析规则。
struct PolicyIconGalleryView: View {
    @State private var query = ""
    @State private var showLicenses = false
    private let categories = ["路由策略", "AI 与模型", "影音娱乐", "社交通讯", "游戏服务", "云服务与工具", "通用服务", "国家与地区", "其他"]

    private var entries: [PolicyIconSpec] {
        PolicyIconCatalog.services + PolicyIconCatalog.continents + PolicyIconCatalog.regions + [PolicyIconCatalog.fallback]
    }

    var body: some View {
        DetailSheet(title: "策略图标") {
            Text("地区采用彩色国旗，品牌与路由符号保持青色，统一尺寸与底座。未识别的名称按策略类型显示通用图标。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            TextField("搜索名称、地区代码或别名", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(categories, id: \.self) { category in
                let filtered = entries.filter {
                    $0.category == category && (query.isEmpty || ($0.aliases + [$0.title]).contains { $0.localizedCaseInsensitiveContains(query) })
                }
                if !filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(category).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 12)], alignment: .leading, spacing: 20) {
                            ForEach(filtered) { spec in
                                VStack(spacing: 8) {
                                    PolicyIconBadge(spec: spec, size: 48)
                                    Text(spec.title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }.padding(.vertical, 8)
                }
            }
            Button("图标来源与许可") { showLicenses = true }
        }
        .appPush(isPresented: $showLicenses) { ThirdPartyLicensesView() }
    }
}
