import SwiftUI

struct CapacityBar: View {
    let percent: Double
    
    var body: some View {
        ZStack(alignment: .leading) {
            // 背景条
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.2))
                
            // 已用容量条
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: min(1.0, max(0.0, percent)) * 60)
        }
        .frame(width: 60, height: 6)
    }
}