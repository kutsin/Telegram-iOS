import Foundation
import Postbox
import MtProtoKit
import SwiftSignalKit
import TelegramApi

import SyncCore

public struct BotPaymentInvoiceFields: OptionSet {
    public var rawValue: Int32
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public init() {
        self.rawValue = 0
    }
    
    public static let name = BotPaymentInvoiceFields(rawValue: 1 << 0)
    public static let phone = BotPaymentInvoiceFields(rawValue: 1 << 1)
    public static let email = BotPaymentInvoiceFields(rawValue: 1 << 2)
    public static let shippingAddress = BotPaymentInvoiceFields(rawValue: 1 << 3)
    public static let flexibleShipping = BotPaymentInvoiceFields(rawValue: 1 << 4)
    public static let phoneAvailableToProvider = BotPaymentInvoiceFields(rawValue: 1 << 5)
    public static let emailAvailableToProvider = BotPaymentInvoiceFields(rawValue: 1 << 6)
}

public struct BotPaymentPrice : Equatable {
    public let label: String
    public let amount: Int64
    
    public init(label: String, amount: Int64) {
        self.label = label
        self.amount = amount
    }
}

public struct BotPaymentInvoice : Equatable {
    public struct Tip: Equatable {
        public var max: Int64
        public var suggested: [Int64]
    }

    public let isTest: Bool
    public let requestedFields: BotPaymentInvoiceFields
    public let currency: String
    public let prices: [BotPaymentPrice]
    public let tip: Tip?
}

public struct BotPaymentNativeProvider : Equatable {
    public let name: String
    public let params: String
}

public struct BotPaymentShippingAddress: Equatable {
    public let streetLine1: String
    public let streetLine2: String
    public let city: String
    public let state: String
    public let countryIso2: String
    public let postCode: String
    
    public init(streetLine1: String, streetLine2: String, city: String, state: String, countryIso2: String, postCode: String) {
        self.streetLine1 = streetLine1
        self.streetLine2 = streetLine2
        self.city = city
        self.state = state
        self.countryIso2 = countryIso2
        self.postCode = postCode
    }
}

public struct BotPaymentRequestedInfo: Equatable {
    public var name: String?
    public var phone: String?
    public var email: String?
    public var shippingAddress: BotPaymentShippingAddress?
    
    public init(name: String?, phone: String?, email: String?, shippingAddress: BotPaymentShippingAddress?) {
        self.name = name
        self.phone = phone
        self.email = email
        self.shippingAddress = shippingAddress
    }
}

public enum BotPaymentSavedCredentials: Equatable {
    case card(id: String, title: String)
    
    public static func ==(lhs: BotPaymentSavedCredentials, rhs: BotPaymentSavedCredentials) -> Bool {
        switch lhs {
            case let .card(id, title):
                if case .card(id, title) = rhs {
                    return true
                } else {
                    return false
                }
        }
    }
}

public struct BotPaymentForm : Equatable {
    public let id: Int64
    public let canSaveCredentials: Bool
    public let passwordMissing: Bool
    public let invoice: BotPaymentInvoice
    public let providerId: PeerId
    public let url: String
    public let nativeProvider: BotPaymentNativeProvider?
    public let savedInfo: BotPaymentRequestedInfo?
    public let savedCredentials: BotPaymentSavedCredentials?
}

public enum BotPaymentFormRequestError {
    case generic
}

extension BotPaymentInvoice {
    init(apiInvoice: Api.Invoice) {
        switch apiInvoice {
            case let .invoice(flags, currency, prices, maxTipAmount, suggestedTipAmounts):
                var fields = BotPaymentInvoiceFields()
                if (flags & (1 << 1)) != 0 {
                    fields.insert(.name)
                }
                if (flags & (1 << 2)) != 0 {
                    fields.insert(.phone)
                }
                if (flags & (1 << 3)) != 0 {
                    fields.insert(.email)
                }
                if (flags & (1 << 4)) != 0 {
                    fields.insert(.shippingAddress)
                }
                if (flags & (1 << 5)) != 0 {
                    fields.insert(.flexibleShipping)
                }
                if (flags & (1 << 6)) != 0 {
                    fields.insert(.phoneAvailableToProvider)
                }
                if (flags & (1 << 7)) != 0 {
                    fields.insert(.emailAvailableToProvider)
                }
                var parsedTip: BotPaymentInvoice.Tip?
                if let maxTipAmount = maxTipAmount, let suggestedTipAmounts = suggestedTipAmounts {
                    parsedTip = BotPaymentInvoice.Tip(max: maxTipAmount, suggested: suggestedTipAmounts)
                }
                self.init(isTest: (flags & (1 << 0)) != 0, requestedFields: fields, currency: currency, prices: prices.map {
                    switch $0 {
                        case let .labeledPrice(label, amount):
                            return BotPaymentPrice(label: label, amount: amount)
                    }
                }, tip: parsedTip)
        }
    }
}

extension BotPaymentRequestedInfo {
    init(apiInfo: Api.PaymentRequestedInfo) {
        switch apiInfo {
            case let .paymentRequestedInfo(_, name, phone, email, shippingAddress):
                var parsedShippingAddress: BotPaymentShippingAddress?
                if let shippingAddress = shippingAddress {
                    switch shippingAddress {
                    case let .postAddress(streetLine1, streetLine2, city, state, countryIso2, postCode):
                        parsedShippingAddress = BotPaymentShippingAddress(streetLine1: streetLine1, streetLine2: streetLine2, city: city, state: state, countryIso2: countryIso2, postCode: postCode)
                    }
                }
                self.init(name: name, phone: phone, email: email, shippingAddress: parsedShippingAddress)
        }
    }
}

public func fetchBotPaymentForm(postbox: Postbox, network: Network, messageId: MessageId, themeParams: [String: Any]?) -> Signal<BotPaymentForm, BotPaymentFormRequestError> {
    return postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(messageId.peerId).flatMap(apiInputPeer)
    }
    |> castError(BotPaymentFormRequestError.self)
    |> mapToSignal { inputPeer -> Signal<BotPaymentForm, BotPaymentFormRequestError> in
        guard let inputPeer = inputPeer else {
            return .fail(.generic)
        }
        var flags: Int32 = 0
        var serializedThemeParams: Api.DataJSON?
        if let themeParams = themeParams, let data = try? JSONSerialization.data(withJSONObject: themeParams, options: []), let dataString = String(data: data, encoding: .utf8) {
            serializedThemeParams = Api.DataJSON.dataJSON(data: dataString)
        }
        if serializedThemeParams != nil {
            flags |= 1 << 0
        }

        return network.request(Api.functions.payments.getPaymentForm(flags: flags, peer: inputPeer, msgId: messageId.id, themeParams: serializedThemeParams))
        |> `catch` { _ -> Signal<Api.payments.PaymentForm, BotPaymentFormRequestError> in
            return .fail(.generic)
        }
        |> mapToSignal { result -> Signal<BotPaymentForm, BotPaymentFormRequestError> in
            return postbox.transaction { transaction -> BotPaymentForm in
                switch result {
                    case let .paymentForm(flags, id, _, invoice, providerId, url, nativeProvider, nativeParams, savedInfo, savedCredentials, apiUsers):
                        var peers: [Peer] = []
                        for user in apiUsers {
                            let parsed = TelegramUser(user: user)
                            peers.append(parsed)
                        }
                        updatePeers(transaction: transaction, peers: peers, update: { _, updated in
                            return updated
                        })

                        let parsedInvoice = BotPaymentInvoice(apiInvoice: invoice)
                        var parsedNativeProvider: BotPaymentNativeProvider?
                        if let nativeProvider = nativeProvider, let nativeParams = nativeParams {
                            switch nativeParams {
                                case let .dataJSON(data):
                                parsedNativeProvider = BotPaymentNativeProvider(name: nativeProvider, params: data)
                            }
                        }
                        let parsedSavedInfo = savedInfo.flatMap(BotPaymentRequestedInfo.init)
                        var parsedSavedCredentials: BotPaymentSavedCredentials?
                        if let savedCredentials = savedCredentials {
                            switch savedCredentials {
                                case let .paymentSavedCredentialsCard(id, title):
                                    parsedSavedCredentials = .card(id: id, title: title)
                            }
                        }
                        return BotPaymentForm(id: id, canSaveCredentials: (flags & (1 << 2)) != 0, passwordMissing: (flags & (1 << 3)) != 0, invoice: parsedInvoice, providerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt32Value(providerId)), url: url, nativeProvider: parsedNativeProvider, savedInfo: parsedSavedInfo, savedCredentials: parsedSavedCredentials)
                }
            }
            |> mapError { _ -> BotPaymentFormRequestError in }
        }
    }
}

public enum ValidateBotPaymentFormError {
    case generic
    case shippingNotAvailable
    case addressStateInvalid
    case addressPostcodeInvalid
    case addressCityInvalid
    case nameInvalid
    case emailInvalid
    case phoneInvalid
}

public struct BotPaymentShippingOption : Equatable {
    public let id: String
    public let title: String
    public let prices: [BotPaymentPrice]
}

public struct BotPaymentValidatedFormInfo : Equatable {
    public let id: String?
    public let shippingOptions: [BotPaymentShippingOption]?
}

extension BotPaymentShippingOption {
    init(apiOption: Api.ShippingOption) {
        switch apiOption {
            case let .shippingOption(id, title, prices):
                self.init(id: id, title: title, prices: prices.map {
                    switch $0 {
                        case let .labeledPrice(label, amount):
                            return BotPaymentPrice(label: label, amount: amount)
                        }
                })
        }
    }
}

public func validateBotPaymentForm(account: Account, saveInfo: Bool, messageId: MessageId, formInfo: BotPaymentRequestedInfo) -> Signal<BotPaymentValidatedFormInfo, ValidateBotPaymentFormError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(messageId.peerId).flatMap(apiInputPeer)
    }
    |> castError(ValidateBotPaymentFormError.self)
    |> mapToSignal { inputPeer -> Signal<BotPaymentValidatedFormInfo, ValidateBotPaymentFormError> in
        guard let inputPeer = inputPeer else {
            return .fail(.generic)
        }

        var flags: Int32 = 0
        if saveInfo {
            flags |= (1 << 0)
        }
        var infoFlags: Int32 = 0
        if let _ = formInfo.name {
            infoFlags |= (1 << 0)
        }
        if let _ = formInfo.phone {
            infoFlags |= (1 << 1)
        }
        if let _ = formInfo.email {
            infoFlags |= (1 << 2)
        }
        var apiShippingAddress: Api.PostAddress?
        if let address = formInfo.shippingAddress {
            infoFlags |= (1 << 3)
            apiShippingAddress = .postAddress(streetLine1: address.streetLine1, streetLine2: address.streetLine2, city: address.city, state: address.state, countryIso2: address.countryIso2, postCode: address.postCode)
        }
        return account.network.request(Api.functions.payments.validateRequestedInfo(flags: flags, peer: inputPeer, msgId: messageId.id, info: .paymentRequestedInfo(flags: infoFlags, name: formInfo.name, phone: formInfo.phone, email: formInfo.email, shippingAddress: apiShippingAddress)))
        |> mapError { error -> ValidateBotPaymentFormError in
            if error.errorDescription == "SHIPPING_NOT_AVAILABLE" {
                return .shippingNotAvailable
            } else if error.errorDescription == "ADDRESS_STATE_INVALID" {
                return .addressStateInvalid
            } else if error.errorDescription == "ADDRESS_POSTCODE_INVALID" {
                return .addressPostcodeInvalid
            } else if error.errorDescription == "ADDRESS_CITY_INVALID" {
                return .addressCityInvalid
            } else if error.errorDescription == "REQ_INFO_NAME_INVALID" {
                return .nameInvalid
            } else if error.errorDescription == "REQ_INFO_EMAIL_INVALID" {
                return .emailInvalid
            } else if error.errorDescription == "REQ_INFO_PHONE_INVALID" {
                return .phoneInvalid
            } else {
                return .generic
            }
        }
        |> map { result -> BotPaymentValidatedFormInfo in
            switch result {
                case let .validatedRequestedInfo(_, id, shippingOptions):
                    return BotPaymentValidatedFormInfo(id: id, shippingOptions: shippingOptions.flatMap {
                        return $0.map(BotPaymentShippingOption.init)
                    })
            }
        }
    }
}

public enum BotPaymentCredentials {
    case generic(data: String, saveOnServer: Bool)
    case saved(id: String, tempPassword: Data)
    case applePay(data: String)
}

public enum SendBotPaymentFormError {
    case generic
    case precheckoutFailed
    case paymentFailed
    case alreadyPaid
}

public enum SendBotPaymentResult {
    case done
    case externalVerificationRequired(url: String)
}

public func sendBotPaymentForm(account: Account, messageId: MessageId, formId: Int64, validatedInfoId: String?, shippingOptionId: String?, tipAmount: Int64?, credentials: BotPaymentCredentials) -> Signal<SendBotPaymentResult, SendBotPaymentFormError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(messageId.peerId).flatMap(apiInputPeer)
    }
    |> castError(SendBotPaymentFormError.self)
    |> mapToSignal { inputPeer -> Signal<SendBotPaymentResult, SendBotPaymentFormError> in
        guard let inputPeer = inputPeer else {
            return .fail(.generic)
        }

        let apiCredentials: Api.InputPaymentCredentials
        switch credentials {
            case let .generic(data, saveOnServer):
                var credentialsFlags: Int32 = 0
                if saveOnServer {
                    credentialsFlags |= (1 << 0)
                }
                apiCredentials = .inputPaymentCredentials(flags: credentialsFlags, data: .dataJSON(data: data))
            case let .saved(id, tempPassword):
                apiCredentials = .inputPaymentCredentialsSaved(id: id, tmpPassword: Buffer(data: tempPassword))
            case let .applePay(data):
                apiCredentials = .inputPaymentCredentialsApplePay(paymentData: .dataJSON(data: data))
        }
        var flags: Int32 = 0
        if validatedInfoId != nil {
            flags |= (1 << 0)
        }
        if shippingOptionId != nil {
            flags |= (1 << 1)
        }
        if tipAmount != nil {
            flags |= (1 << 2)
        }
        return account.network.request(Api.functions.payments.sendPaymentForm(flags: flags, formId: formId, peer: inputPeer, msgId: messageId.id, requestedInfoId: validatedInfoId, shippingOptionId: shippingOptionId, credentials: apiCredentials, tipAmount: tipAmount))
        |> map { result -> SendBotPaymentResult in
            switch result {
                case let .paymentResult(updates):
                    account.stateManager.addUpdates(updates)
                    return .done
                case let .paymentVerificationNeeded(url):
                    return .externalVerificationRequired(url: url)
            }
        }
        |> `catch` { error -> Signal<SendBotPaymentResult, SendBotPaymentFormError> in
            if error.errorDescription == "BOT_PRECHECKOUT_FAILED" {
                return .fail(.precheckoutFailed)
            } else if error.errorDescription == "PAYMENT_FAILED" {
                return .fail(.paymentFailed)
            } else if error.errorDescription == "INVOICE_ALREADY_PAID" {
                return .fail(.alreadyPaid)
            }
            return .fail(.generic)
        }
    }
}

public struct BotPaymentReceipt {
    public let invoice: BotPaymentInvoice
    public let info: BotPaymentRequestedInfo?
    public let shippingOption: BotPaymentShippingOption?
    public let credentialsTitle: String
    public let invoiceMedia: TelegramMediaInvoice
    public let tipAmount: Int64?
}

public enum RequestBotPaymentReceiptError {
    case generic
}

public func requestBotPaymentReceipt(account: Account, messageId: MessageId) -> Signal<BotPaymentReceipt, RequestBotPaymentReceiptError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(messageId.peerId).flatMap(apiInputPeer)
    }
    |> castError(RequestBotPaymentReceiptError.self)
    |> mapToSignal { inputPeer -> Signal<BotPaymentReceipt, RequestBotPaymentReceiptError> in
        guard let inputPeer = inputPeer else {
            return .fail(.generic)
        }

        return account.network.request(Api.functions.payments.getPaymentReceipt(peer: inputPeer, msgId: messageId.id))
        |> mapError { _ -> RequestBotPaymentReceiptError in
            return .generic
        }
        |> mapToSignal { result -> Signal<BotPaymentReceipt, RequestBotPaymentReceiptError> in
            return account.postbox.transaction { transaction -> BotPaymentReceipt in
                switch result {
                case let .paymentReceipt(flags, date, botId, providerId, title, description, photo, invoice, info, shipping, tipAmount, currency, totalAmount, credentialsTitle, users):
                    var peers: [Peer] = []
                    for user in users {
                        peers.append(TelegramUser(user: user))
                    }
                    updatePeers(transaction: transaction, peers: peers, update: { _, updated in return updated })

                    let parsedInvoice = BotPaymentInvoice(apiInvoice: invoice)
                    let parsedInfo = info.flatMap(BotPaymentRequestedInfo.init)
                    let shippingOption = shipping.flatMap(BotPaymentShippingOption.init)

                    /*let fields = BotPaymentInvoiceFields()

                    let form = BotPaymentForm(
                        id: 0,
                        canSaveCredentials: false,
                        passwordMissing: false,
                        invoice: BotPaymentInvoice(
                            isTest: false,
                            requestedFields: fields,
                            currency: currency,
                            prices: [],
                            tip: nil
                        ),
                        providerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt32Value(providerId)),
                        url: "",
                        nativeProvider: nil,
                        savedInfo: nil,
                        savedCredentials: nil
                    )*/

                    let invoiceMedia = TelegramMediaInvoice(
                        title: title,
                        description: description,
                        photo: photo.flatMap(TelegramMediaWebFile.init),
                        receiptMessageId: nil,
                        currency: currency,
                        totalAmount: totalAmount,
                        startParam: "",
                        flags: []
                    )

                    return BotPaymentReceipt(invoice: parsedInvoice, info: parsedInfo, shippingOption: shippingOption, credentialsTitle: credentialsTitle, invoiceMedia: invoiceMedia, tipAmount: tipAmount)
                }
            }
            |> castError(RequestBotPaymentReceiptError.self)
        }
    }
}

public struct BotPaymentInfo: OptionSet {
    public var rawValue: Int32
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public init() {
        self.rawValue = 0
    }
    
    public static let paymentInfo = BotPaymentInfo(rawValue: 1 << 0)
    public static let shippingInfo = BotPaymentInfo(rawValue: 1 << 1)
}

public func clearBotPaymentInfo(network: Network, info: BotPaymentInfo) -> Signal<Void, NoError> {
    var flags: Int32 = 0
    if info.contains(.paymentInfo) {
        flags |= (1 << 0)
    }
    if info.contains(.shippingInfo) {
        flags |= (1 << 1)
    }
    return network.request(Api.functions.payments.clearSavedInfo(flags: flags))
    |> retryRequest
    |> mapToSignal { _ -> Signal<Void, NoError> in
        return .complete()
    }
}
