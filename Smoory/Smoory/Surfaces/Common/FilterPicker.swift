import SwiftUI

/// Capsule-shaped filter pill used for "All / X / Y" style selectors. Tinted as
/// secondary when the "neutral" case is selected (`isAllCase` returns true) so
/// the user reads "no filter applied"; tinted as primary otherwise.
struct FilterPicker<Filter: Hashable & CaseIterable>: View
where Filter.AllCases: RandomAccessCollection {
    @Binding var selected: Filter
    let titleProvider: (Filter) -> String
    let isAllCase: (Filter) -> Bool

    var body: some View {
        Menu {
            ForEach(Array(Filter.allCases), id: \.self) { option in
                Button(titleProvider(option)) { selected = option }
            }
        } label: {
            HStack(spacing: 4) {
                Text(titleProvider(selected))
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .font(.smoory_caption)
            .foregroundStyle(isAllCase(selected) ? .secondary : .primary)
            .background(Color.secondary.opacity(isAllCase(selected) ? 0.06 : 0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
