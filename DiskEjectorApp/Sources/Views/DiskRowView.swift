import SwiftUI

struct DiskRowView: View {
    let disk: DiskInfo
    
    var body: some View {
        HStack {
            Image(systemName: "externaldrive.fill")
                .foregroundColor(.accentColor)
            Text(disk.displayName)
                .font(.body)
            Spacer()
            Button(action: {
                // 推出磁盘
            }) {
                Image(systemName: "eject.fill")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }
}
