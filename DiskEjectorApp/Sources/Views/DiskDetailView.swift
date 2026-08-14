import SwiftUI

struct DiskDetailView: View {
    let disk: DiskInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .foregroundColor(.accentColor)
                Text(disk.displayName)
                    .font(.largeTitle)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: L10n.tr(.totalCapacityFormat), disk.totalFormatted))
                Text(String(format: L10n.tr(.availableSpaceFormat), disk.freeFormatted))
                Text(String(format: L10n.tr(.mountPathFormat), disk.mountPath))
            }
            
            Spacer()
            
            Button(action: {
                // 推出磁盘
            }) {
                Text(L10n.tr(.eject))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(8)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
}