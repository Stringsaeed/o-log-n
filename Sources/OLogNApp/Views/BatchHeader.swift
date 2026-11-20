import SwiftUI

struct BatchHeader: View {
    let count: Int
    let saved: Int64
    @Environment(\.colorScheme) private var scheme
    @Environment(PanelCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 8) {
            Text("Batch · \(count) files")
                .font(LognFont.meta)
                .foregroundStyle(Color.primary.opacity(0.82))
            Spacer(minLength: 8)
            if saved > 0 {
                Text("−\(ByteText.string(saved))")
                    .font(LognFont.metric)
                    .foregroundStyle(LognColor.emeraldText(scheme))
                    .ticker(value: saved, enabled: !coordinator.reduceMotion)
                    .padding(.trailing, 134)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Batch of \(count) files")
    }
}
