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
                Text("总容量: \(disk.totalFormatted)")
                Text("可用空间: \(disk.freeFormatted)")
                Text("挂载路径: \(disk.mountPath)")
            }
            
            Spacer()
            
            Button(action: {
                // 推出磁盘
            }) {
                Text("推出")
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