import Foundation
import UIKit
import SuperwallKit
import BillDogFull

// The controller reaches BillDog and Superwall through these two seams. Both
// SDKs are singletons that need live accounts to do anything, so code written
// against them directly cannot be exercised. Behind the seams the controller's
// behaviour — what a purchase result becomes, when the subscription status is
// pushed, who Superwall is told the user is — is covered by tests that run
// against fakes.

/// The part of the BillDog SDK the controller uses. `BillDog` conforms.
@available(iOS 15.0, *)
public protocol SuperwallBillDogBackend: AnyObject {
    func purchase(productId: String) async throws -> BillDogFull.PurchaseResult
    func restorePurchases() async throws -> BillDogFull.RestoreResult
    func getCustomerInfo(forceRefresh: Bool) async throws -> BillDogFull.CustomerInfo
    var customerInfoStream: AsyncStream<BillDogFull.CustomerInfo> { get }
    var isAnonymous: Bool { get }
    var appUserId: String? { get }
    func purchaseViaWeb(productId: String, from presenter: UIViewController) async throws -> String
    func redeemAndNotify(token: String, appUserId: String?) async -> RedemptionOutcome
    func trackEvent(_ name: String, properties: [String: Any])
    /// A purchase with typed params: the controller names the offering the purchase is
    /// attributed to in `PurchaseParams.presentedOfferingContext`.
    func purchase(params: PurchaseParams) async throws -> BillDogFull.PurchaseResult
    /// A loaded offering, by identifier; nil when it is not loaded.
    func getOffering(identifier: String) -> BillDogFull.Offering?
}

@available(iOS 15.0, *)
public extension SuperwallBillDogBackend {
    /// For a backend written before attribution: the purchase by product id alone.
    func purchase(params: PurchaseParams) async throws -> BillDogFull.PurchaseResult {
        try await purchase(productId: params.productId)
    }

    /// For a backend written before attribution: no offering is known.
    func getOffering(identifier: String) -> BillDogFull.Offering? { nil }
}

@available(iOS 15.0, *)
extension BillDog: SuperwallBillDogBackend {}

/// The part of Superwall the controller drives.
@available(iOS 15.0, *)
public protocol SuperwallStatusSink: AnyObject {
    /// Entitlement ids the user holds. Empty means no active subscription.
    @MainActor func setActiveEntitlements(_ ids: Set<String>)
    @MainActor func identify(userId: String)
    @MainActor func reset()
    @MainActor func dismissPaywall() async
    /// The identifier, set in the Superwall dashboard, of the paywall Superwall has on
    /// screen; nil when none is presented.
    @MainActor var presentedPaywallIdentifier: String? { get }
}

@available(iOS 15.0, *)
public extension SuperwallStatusSink {
    /// For a sink written before attribution: no paywall is known to be on screen.
    @MainActor var presentedPaywallIdentifier: String? { nil }
}

/// `SuperwallStatusSink` over `Superwall.shared`.
@available(iOS 15.0, *)
public final class SharedSuperwallSink: SuperwallStatusSink {
    public init() {}

    @MainActor public func setActiveEntitlements(_ ids: Set<String>) {
        Superwall.shared.subscriptionStatus = ids.isEmpty
            ? .inactive
            : .active(Set(ids.map { SuperwallKit.Entitlement(id: $0) }))
    }

    @MainActor public func identify(userId: String) {
        Superwall.shared.identify(userId: userId)
    }

    @MainActor public func reset() {
        Superwall.shared.reset()
    }

    @MainActor public func dismissPaywall() async {
        await Superwall.shared.dismiss()
    }

    /// The paywall on screen only: `presentedViewController` is cleared when the paywall
    /// is dismissed, unlike `latestPaywallInfo`, which keeps the last one shown.
    @MainActor public var presentedPaywallIdentifier: String? {
        (Superwall.shared.presentedViewController as? SuperwallKit.PaywallViewController)?.info.identifier
    }
}
