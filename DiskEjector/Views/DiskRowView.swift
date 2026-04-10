import SwiftUI

struct DiskRowView: View {
    let disk: DiskInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(disk.displayName)
                    .font(.system(.body, design: .default, weight: .medium))
                    .lineLimit(1)

                Text(disk.capacityLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Fixed-size capacity bar
            CapacityBar(percent: disk.usagePercent)
                .frame(width: 60, height: 6)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}