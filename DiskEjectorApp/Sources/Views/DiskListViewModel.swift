import Foundation

class DiskListViewModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    
    init() {
        fetchDisks()
    }
    
    func fetchDisks() {
        disks = DiskService.shared.fetchExternalDisks()
    }
}