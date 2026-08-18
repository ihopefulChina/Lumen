import Foundation
import Security
import Testing
@testable import Ossuno

@MainActor
struct AccountSheetTests {
    @Test func lockedKeychainOffersUnlockGuidanceAndKeychainAccess() {
        let failure = AccountFormFailure(
            operation: .savingAccount,
            error: KeychainStoreError(status: errSecInteractionNotAllowed)
        )

        #expect(failure.category == .keychainLocked)
        #expect(failure.title == "无法保存账号凭证")
        #expect(failure.isKeychainFailure)
        #expect(failure.shouldOfferKeychainAccess)
        #expect(failure.retryTitle == "重新尝试")
        #expect(failure.recoverySuggestion.contains("已解锁"))
        #expect(failure.recoverySuggestion.contains("仍保留"))
        #expect(failure.accessibilityAnnouncement.contains("无法保存账号凭证"))
    }

    @Test func missingEntitlementPointsToASignedReleaseAndNeverUnlocking() {
        let failure = AccountFormFailure(
            operation: .savingAccount,
            error: KeychainStoreError(status: errSecMissingEntitlement)
        )

        #expect(failure.category == .keychainMissingEntitlement)
        #expect(failure.title == "无法保存账号凭证")
        #expect(failure.requiresReinstallation)
        #expect(!failure.shouldOfferKeychainAccess)
        #expect(failure.recoverySuggestion.contains("官方发布页"))
        #expect(failure.recoverySuggestion.contains("经过签名"))
        #expect(!failure.recoverySuggestion.contains("解锁"))
    }

    @Test func deniedKeychainAccessExplainsTheSystemPermissionAction() {
        let failure = AccountFormFailure(
            operation: .savingAccount,
            error: KeychainStoreError(status: errSecAuthFailed)
        )

        #expect(failure.category == .keychainAccessDenied)
        #expect(failure.shouldOfferKeychainAccess)
        #expect(failure.recoverySuggestion.contains("选择允许 Ossuno 访问"))
        #expect(failure.recoverySuggestion.contains("仍保留"))
    }

    @Test func networkFailureDoesNotSuggestKeychainRecovery() {
        let failure = AccountFormFailure(
            operation: .savingAccount,
            error: URLError(.timedOut)
        )

        #expect(failure.category == .connection)
        #expect(failure.title == "无法连接账号")
        #expect(!failure.shouldOfferKeychainAccess)
        #expect(!failure.isKeychainFailure)
        #expect(failure.recoverySuggestion.contains("AccessKey、Endpoint 和网络"))
    }

    @Test func credentialRollbackGetsADedicatedRecoveryMessage() {
        let failure = AccountFormFailure(
            operation: .savingAccount,
            error: AccountStoreError.rollbackFailed(primary: "写入失败", rollback: "恢复失败")
        )

        #expect(failure.category == .credentialRollback)
        #expect(failure.title == "账号凭证恢复失败")
        #expect(!failure.shouldOfferKeychainAccess)
        #expect(failure.recoverySuggestion.contains("未能自动恢复"))
    }

    @Test func credentialLoadFailureUsesAReadSpecificRetry() {
        let failure = AccountFormFailure(
            operation: .loadingCredentials,
            error: KeychainStoreError(status: errSecInteractionNotAllowed)
        )

        #expect(failure.title == "无法读取账号凭证")
        #expect(failure.retryTitle == "重新读取")
        #expect(failure.retryHelp.contains("重新从 macOS 钥匙串读取"))
    }
}
