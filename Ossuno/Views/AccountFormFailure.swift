import Foundation
import Security

struct AccountFormFailure: Equatable {
    enum Operation: Equatable {
        case loadingCredentials
        case savingAccount
    }

    enum Category: Equatable {
        case keychainMissingEntitlement
        case keychainLocked
        case keychainAccessDenied
        case keychainUnavailable
        case keychainAuthorizationCancelled
        case keychainInvalidData
        case keychainOther
        case credentialRollback
        case connection
        case localAccountStorage
        case unknown

        var isKeychain: Bool {
            switch self {
            case .keychainMissingEntitlement, .keychainLocked, .keychainAccessDenied,
                 .keychainUnavailable, .keychainAuthorizationCancelled,
                 .keychainInvalidData, .keychainOther:
                true
            case .credentialRollback, .connection, .localAccountStorage, .unknown:
                false
            }
        }
    }

    let operation: Operation
    let category: Category
    let message: String

    init(operation: Operation, error: Error) {
        self.operation = operation
        self.category = Self.category(for: error)
        self.message = error.localizedDescription
    }

    var shouldOfferKeychainAccess: Bool {
        switch category {
        case .keychainLocked, .keychainAccessDenied, .keychainUnavailable,
             .keychainInvalidData, .keychainOther:
            true
        case .keychainMissingEntitlement, .keychainAuthorizationCancelled,
             .credentialRollback, .connection, .localAccountStorage, .unknown:
            false
        }
    }

    var isKeychainFailure: Bool {
        category.isKeychain
    }

    var requiresReinstallation: Bool {
        category == .keychainMissingEntitlement
    }

    var title: String {
        switch category {
        case .credentialRollback:
            return "账号凭证恢复失败"
        case .localAccountStorage:
            return operation == .savingAccount ? "无法保存账号配置" : "无法读取账号配置"
        default:
            break
        }
        return switch (operation, category.isKeychain) {
        case (.savingAccount, true):
            "无法保存账号凭证"
        case (.loadingCredentials, true):
            "无法读取账号凭证"
        case (.savingAccount, false):
            "无法连接账号"
        case (.loadingCredentials, false):
            "无法读取账号信息"
        }
    }

    var recoverySuggestion: String {
        switch category {
        case .keychainMissingEntitlement:
            return "请安装来自 Ossuno 官方发布页、且经过签名的最新版本后重新尝试。你填写的内容仍保留在此表单中。"
        case .keychainLocked:
            return "请确认“登录”钥匙串已解锁并允许 Ossuno 访问，然后重新尝试。你填写的内容仍保留在此表单中。"
        case .keychainAccessDenied:
            return "请重新尝试，并在 macOS 的钥匙串提示中选择允许 Ossuno 访问。你填写的内容仍保留在此表单中。"
        case .keychainUnavailable:
            return "请打开“钥匙串访问”，确认“登录”钥匙串可用后重新尝试。你填写的内容仍保留在此表单中。"
        case .keychainAuthorizationCancelled:
            return "请重新尝试，并在 macOS 的钥匙串提示中完成授权。你填写的内容仍保留在此表单中。"
        case .keychainInvalidData:
            return "请重新填写凭证后再试；如仍失败，请打开“钥匙串访问”检查 Ossuno 项目。当前账号不会被覆盖。"
        case .keychainOther:
            return "请打开“钥匙串访问”检查登录钥匙串状态，然后重新尝试。你填写的内容仍保留在此表单中。"
        case .credentialRollback:
            return "账号配置和原凭证未能自动恢复。请保留当前输入，先根据上方错误处理，再重新尝试。"
        case .connection:
            return "请检查 AccessKey、Endpoint 和网络后重新尝试。你填写的内容仍保留在此表单中。"
        case .localAccountStorage:
            return "请确认磁盘空间充足且 Ossuno 可以写入应用支持目录，然后重新尝试。你填写的内容仍保留在此表单中。"
        case .unknown:
            switch operation {
            case .savingAccount:
                return "请根据上方错误处理后重新尝试。你填写的内容仍保留在此表单中。"
            case .loadingCredentials:
                return "请稍后重新读取凭证；在读取成功前，当前账号不会被覆盖。"
            }
        }
    }

    var retryTitle: String {
        switch operation {
        case .savingAccount: "重新尝试"
        case .loadingCredentials: "重新读取"
        }
    }

    var retryHelp: String {
        switch operation {
        case .savingAccount: "使用当前表单内容重新连接并保存账号"
        case .loadingCredentials: "重新从 macOS 钥匙串读取账号凭证"
        }
    }

    var accessibilityAnnouncement: String {
        "错误：\(title)。\(message)。\(recoverySuggestion)"
    }

    private static func category(for error: Error) -> Category {
        if let keychainError = error as? KeychainStoreError {
            switch keychainError {
            case .status(let status):
                switch status {
                case errSecMissingEntitlement: return .keychainMissingEntitlement
                case errSecInteractionNotAllowed: return .keychainLocked
                case errSecAuthFailed: return .keychainAccessDenied
                case errSecNotAvailable: return .keychainUnavailable
                case errSecUserCanceled: return .keychainAuthorizationCancelled
                default: return .keychainOther
                }
            case .invalidData:
                return .keychainInvalidData
            case .rollbackFailed:
                return .credentialRollback
            }
        }
        if error is AccountStoreError {
            return .credentialRollback
        }
        if error is AccountRepositoryError || (error as NSError).domain == NSCocoaErrorDomain {
            return .localAccountStorage
        }
        if error is OSSServiceError || error is URLError {
            return .connection
        }
        return .unknown
    }
}
