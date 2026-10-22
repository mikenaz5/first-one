import Foundation
import PassKit
#if canImport(StripeApplePay)
import StripeApplePay
#endif

/// What the payment sheet needs to show and charge.
struct PaymentRequestDetails: Equatable {
    var info: PaymentIntentInfo
    /// Shown on the Apple Pay sheet, for example "Deposit · Portrait session".
    var label: String
    /// The country the creator is paid in. Apple Pay needs it; it isn't a language or region setting.
    var countryCode: String
}

enum PaymentAuthorization: Equatable {
    case paid
    /// They closed the sheet without paying.
    case cancelled
}

/// Shows the payment sheet and reports whether the person paid. It never decides what happens next:
/// the booking changes only when the backend hears from Stripe that the money arrived.
@MainActor
protocol PaymentAuthorizer: AnyObject {
    func authorize(_ request: PaymentRequestDetails) async throws -> PaymentAuthorization
}

enum PaymentAuthorizerFactory {
    @MainActor
    static func make(for backend: any SlateBackend) -> any PaymentAuthorizer {
        if backend.paymentsAreSimulated { return SimulatedPaymentAuthorizer() }
        if let config = AppConfig.stripe {
            return ApplePayAuthorizer(publishableKey: config.publishableKey, merchantID: config.merchantID)
        }
        return UnconfiguredPaymentAuthorizer()
    }
}

/// On-device mode: approving is instant and no card is involved.
@MainActor
final class SimulatedPaymentAuthorizer: PaymentAuthorizer {
    func authorize(_ request: PaymentRequestDetails) async throws -> PaymentAuthorization { .paid }
}

/// A server-backed build with no Stripe keys: say so plainly instead of failing mysteriously.
@MainActor
final class UnconfiguredPaymentAuthorizer: PaymentAuthorizer {
    func authorize(_ request: PaymentRequestDetails) async throws -> PaymentAuthorization {
        throw SlateError.paymentsNotConfigured
    }
}

#if canImport(StripeApplePay)

/// Apple Pay through Stripe. Apple Pay hands Stripe an encrypted card token; Stripe confirms the PaymentIntent
/// the backend created (using the client secret), so card details never reach this app or our server.
///
/// This has never been run on a device with a real Apple Pay wallet.
@MainActor
final class ApplePayAuthorizer: NSObject, PaymentAuthorizer, ApplePayContextDelegate {
    private let merchantID: String
    private var clientSecret: String?
    private var continuation: CheckedContinuation<PaymentAuthorization, Error>?

    init(publishableKey: String, merchantID: String) {
        self.merchantID = merchantID
        super.init()
        StripeAPI.defaultPublishableKey = publishableKey
    }

    func authorize(_ request: PaymentRequestDetails) async throws -> PaymentAuthorization {
        guard let secret = request.info.clientSecret else { throw SlateError.paymentUnavailable }
        guard StripeAPI.deviceSupportsApplePay() else { throw SlateError.applePayUnavailable }

        let paymentRequest = StripeAPI.paymentRequest(
            withMerchantIdentifier: merchantID,
            country: request.countryCode,
            currency: request.info.currencyCode
        )
        paymentRequest.paymentSummaryItems = [
            PKPaymentSummaryItem(label: request.label, amount: NSDecimalNumber(decimal: Money.decimal(cents: request.info.amountCents))),
        ]
        guard let context = STPApplePayContext(paymentRequest: paymentRequest, delegate: self) else {
            throw SlateError.applePayUnavailable
        }

        clientSecret = secret
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            context.presentApplePay()
        }
    }

    // MARK: ApplePayContextDelegate

    func applePayContext(
        _ context: STPApplePayContext,
        didCreatePaymentMethod paymentMethod: StripeAPI.PaymentMethod,
        paymentInformation: PKPayment,
        completion: @escaping (String?, Error?) -> Void
    ) {
        // Stripe now confirms this PaymentIntent with the Apple Pay card the person chose.
        completion(clientSecret, nil)
    }

    func applePayContext(_ context: STPApplePayContext, didCompleteWith status: STPApplePayContext.PaymentStatus, error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        clientSecret = nil
        switch status {
        case .success:
            continuation?.resume(returning: .paid)
        case .userCancellation:
            continuation?.resume(returning: .cancelled)
        case .error:
            continuation?.resume(throwing: error ?? SlateError.paymentUnavailable)
        @unknown default:
            continuation?.resume(throwing: SlateError.paymentUnavailable)
        }
    }
}

#else

/// Stripe's SDK isn't linked into this build.
@MainActor
final class ApplePayAuthorizer: PaymentAuthorizer {
    init(publishableKey: String, merchantID: String) {}

    func authorize(_ request: PaymentRequestDetails) async throws -> PaymentAuthorization {
        throw SlateError.paymentsNotConfigured
    }
}

#endif
