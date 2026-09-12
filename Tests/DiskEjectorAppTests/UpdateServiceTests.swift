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

    /// 直发版必须指向**真实存在**的 Releases 页。
    ///
    /// 这个常量填错既不会编译失败，也不会在开发环境暴露，只会在用户点「打开下载页」
    /// 时落到 404——和 App Store 标识符是同一类风险，所以同样用测试钉住。
    @Test func 直发版下载页指向本仓库的releases() throws {
        let url = try #require(UpdateService.updateSourceURL)
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path.hasSuffix("/releases"))
    }

    /// 常量已配置，直发/开发渠道都应给出入口。
    ///
    /// 原先这里有一条「未配置常量时无更新入口」的测试，断言 `updateSourceURL == nil`。
    /// 常量填上后该断言必然为假，遂删除——**不是**覆盖度回退：守卫逻辑本身仍在
    /// `canOpenUpdateSource` 里，且 App Store 分支（`appStoreID` 尚未配置）依然走
    /// 「不给出入口」这条路，只是它在测试进程内无法触达。
    @Test func 已配置下载页时给出更新入口() {
        #expect(UpdateService.canOpenUpdateSource)
    }
}
