import Foundation
import Testing

@testable import DiskEjectorApp

/// 更新入口的测试。
///
/// 这里锁定的不是业务逻辑，而是**上线时最容易填错的那个字符串**。
/// App Store Connect 给的是纯数字，链接要的是 `id` 前缀，填错不会编译失败、
/// 也不会在开发环境暴露，只会在上架后把用户导向 404。
@Suite("更新服务")
struct UpdateServiceTests {

    @Test func 纯数字自动补id前缀() {
        #expect(UpdateService.normalizedAppStoreID("1234567890") == "id1234567890")
    }

    @Test func 已带id前缀时原样返回() {
        #expect(UpdateService.normalizedAppStoreID("id1234567890") == "id1234567890")
    }

    @Test func 空值与nil不产生标识符() {
        #expect(UpdateService.normalizedAppStoreID(nil) == nil)
        #expect(UpdateService.normalizedAppStoreID("") == nil)
    }

    /// 常量未配置时，绝不能给出可点击的入口——点了没反应的按钮比没有按钮更糟。
    @Test func 未配置常量时无更新入口() {
        #expect(UpdateService.updateSourceURL == nil)
        #expect(UpdateService.canOpenUpdateSource == false)
    }
}
