import SwiftUI

/// 原厂列表共用搜索输入，筛选仍在所属页面本地进行。
struct UFISearchField: View {
    let placeholder: String
    @Binding var query: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(12).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

}
