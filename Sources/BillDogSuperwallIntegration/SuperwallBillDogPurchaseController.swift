import Foundation
import UIKit
import SuperwallKit
import BillDogFull

/// Superwall `PurchaseController` (SuperwallKit 4.x) backed by BillDog.
///
/// Superwall presents paywalls; every purchase and restore runs through
/// `BillDog.shared.purchase(productId:)` / `restorePurchases()`, so receipt
/// validation, entitlements, analytics and webhooks stay on BillDog's
/// canonical path.
///
/// With a custom purchase controller Superwall no longer tracks
/// entitlements itself, so the controller also keeps
/// `Superwall.shared.subscriptionStatus` in sync with BillDog's active
/// entitlements, and Superwall's user identified as BillDog's app user id
/// (call `startSyncingSubscriptionStatus()` once after configuring both SDKs).
///
/// Forward `SuperwallDelegate` callbacks to `forwardSuperwallEvent(_:)` and
/// `handleCustomPaywallAction(name:from:)` for analytics and web checkout.
///
/// Superwall presents its own paywall, so BillDog cannot tell which BillDog
/// offering a purchase came from. `offeringMap` says so: the BillDog offering
/// identifier behind each Superwall paywall identifier. A purchase from a mapped
/// paywall is attributed to that offering's package selling the product; any
/// other purchase is attributed as `BillDog.purchase(productId:)` attributes it.
///
/// ```swift
/// BillDog.configure(apiKey: "bd_...")
/// let controller = SuperwallBillDogPurchaseController(
///     offeringMap: ["spring_sale_paywall": "spring_sale"])
/// Superwall.configure(apiKey: "pk_...", purchaseController: controller)
/// controller.startSyncingSubscriptionStatus()
/// ```
@available(iOS 15.0, *)
public final class SuperwallBillDogPurchaseController: PurchaseController {

    private let billDog: SuperwallBillDogBackend
    private let superwall: SuperwallStatusSink
    /// BillDog entitlement identifier → Superwall entitlement id. Identifiers
    /// without an entry pass through unchanged.
    private let entitlementMap: [String: String]
    /// Superwall paywall identifier → BillDog offering identifier.
    private let offeringMap: [String: String]
    /// Identify Superwall's user with BillDog's (non-anonymous) app user id.
    private let syncIdentity: Bool
    private var identifiedUserId: String?
    private var syncTask: Task<Void, Never>?

    public convenience init(
        billDog: BillDog = .shared,
        entitlementMap: [String: String] = [:],
        offeringMap: [String: String] = [:],
        syncIdentity: Bool = true
    ) {
        self.init(
            backend: billDog,
            superwall: SharedSuperwallSink(),
            entitlementMap: entitlementMap,
            offeringMap: offeringMap,
            syncIdentity: syncIdentity
        )
    }

    /// The controller over any BillDog backend and Superwall sink.
    public init(
        backend: SuperwallBillDogBackend,
        superwall: SuperwallStatusSink,
        entitlementMap: [String: String] = [:],
        offeringMap: [String: String] = [:],
        syncIdentity: Bool = true
    ) {
        self.billDog = backend
        self.superwall = superwall
        self.entitlementMap = entitlementMap
        self.offeringMap = offeringMap
        self.syncIdentity = syncIdentity
    }

    deinit {
        syncTask?.cancel()
    }

    // MARK: - PurchaseController

    @MainActor
    public func purchase(product: SuperwallKit.StoreProduct) async -> SuperwallKit.PurchaseResult {
        await purchase(productId: product.productIdentifier)
    }

    /// Buy `productId` through BillDog and report the outcome in Superwall's
    /// terms. `purchase(product:)` is this, with the identifier read off
    /// Superwall's product.
    @MainActor
    public func purchase(productId: String) async -> SuperwallKit.PurchaseResult {
        let result: BillDogFull.PurchaseResult
        do {
            if let context = presentedContext(forProductId: productId) {
                result = try await billDog.purchase(
                    params: PurchaseParams.Builder(productId: productId).with(presentedOfferingContext: context).build())
            } else {
                result = try await billDog.purchase(productId: productId)
            }
        } catch let error as BillDogError {
            if case .userCancelled = error {
                return .cancelled
            }
            return .failed(error)
        } catch {
            return .failed(error)
        }

        switch result {
        case .purchased, .restored:
            await syncSubscriptionStatus()
            return .purchased
        case .cancelled:
            return .cancelled
        case .pending:
            return .pending
        case .failed(let error):
            return .failed(error)
        }
    }

    /// The context of the BillDog offering `offeringMap` names for the Superwall
    /// paywall on screen: its package selling `productId`. Nil — the purchase is
    /// attributed by product id — when no paywall is on screen, the paywall is not
    /// mapped, or its offering is not loaded or does not sell the product.
    @MainActor
    func presentedContext(forProductId productId: String) -> PresentedOfferingContext? {
        guard !offeringMap.isEmpty, let paywall = superwall.presentedPaywallIdentifier else { return nil }
        guard let offeringIdentifier = offeringMap[paywall] else {
            BillDogLogger.d(Self.logTag, "Superwall paywall '\(paywall)' is not in offeringMap; '\(productId)' is attributed by product id")
            return nil
        }
        guard let offering = billDog.getOffering(identifier: offeringIdentifier) else {
            BillDogLogger.w(Self.logTag, "offering '\(offeringIdentifier)' (Superwall paywall '\(paywall)') is not loaded; '\(productId)' is attributed by product id")
            return nil
        }
        guard let package = offering.packages.first(where: { StoreProductReference.storeProductId(of: $0) == productId }) else {
            BillDogLogger.w(Self.logTag, "offering '\(offeringIdentifier)' (Superwall paywall '\(paywall)') does not sell '\(productId)'; it is attributed by product id")
            return nil
        }
        return package.presentedOfferingContext ?? PresentedOfferingContext(offeringId: offering.id)
    }

    private static let logTag = "Superwall"

    @MainActor
    public func restorePurchases() async -> SuperwallKit.RestorationResult {
        do {
            let result = try await billDog.restorePurchases()
            switch result {
            case .restored:
                // An empty restore still succeeded; Superwall decides what to
                // show from the subscription status synced here.
                await syncSubscriptionStatus()
                return .restored
            case .failed(let error):
                return .failed(error)
            }
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Web checkout from a Superwall paywall

    /// Custom-action prefix a Superwall paywall button uses to start BillDog
    /// web checkout: `billdog_web_checkout:<productId>`.
    public static let webCheckoutActionPrefix = "billdog_web_checkout:"

    /// Call from `SuperwallDelegate.handleCustomPaywallAction(withName:)`.
    /// For `billdog_web_checkout:<productId>` it opens BillDog web checkout,
    /// redeems the returned token, syncs the subscription status and dismisses
    /// the Superwall paywall. Returns false for any other action name, or when
    /// checkout or redemption did not complete.
    ///
    /// ```swift
    /// func handleCustomPaywallAction(withName name: String) {
    ///     guard let presenter = Superwall.shared.presentedViewController else { return }
    ///     Task { await controller.handleCustomPaywallAction(name: name, from: presenter) }
    /// }
    /// ```
    @MainActor
    @discardableResult
    public func handleCustomPaywallAction(name: String, from presenter: UIViewController) async -> Bool {
        guard name.hasPrefix(Self.webCheckoutActionPrefix) else { return false }
        let productId = String(name.dropFirst(Self.webCheckoutActionPrefix.count))
        guard !productId.isEmpty else { return false }

        let token: String
        do {
            token = try await billDog.purchaseViaWeb(productId: productId, from: presenter)
        } catch {
            return false
        }
        guard case .success = await billDog.redeemAndNotify(token: token, appUserId: nil) else {
            return false
        }
        await syncSubscriptionStatus()
        await superwall.dismissPaywall()
        return true
    }

    // MARK: - Superwall analytics forwarding

    /// Forward a Superwall analytics event into BillDog analytics as
    /// `superwall_<event>` (e.g. `superwall_paywall_open`), so paywall
    /// funnels sit next to BillDog's purchase and entitlement data. Call from
    /// `SuperwallDelegate.handleSuperwallEvent(withInfo:)`. Only scalar
    /// parameters are forwarded.
    public func forwardSuperwallEvent(_ eventInfo: SuperwallEventInfo) {
        forwardSuperwallEvent(name: eventInfo.event.description, params: eventInfo.params)
    }

    /// `forwardSuperwallEvent(_:)` for an event given by name.
    public func forwardSuperwallEvent(name: String, params: [String: Any]) {
        billDog.trackEvent("superwall_\(name)", properties: Self.scalarProperties(params))
    }

    static func scalarProperties(_ params: [String: Any]) -> [String: Any] {
        params.filter { _, value in
            value is String || value is Bool || value is Int || value is Double || value is NSNumber
        }
    }

    // MARK: - Subscription status sync

    /// Push BillDog's active entitlements to Superwall now, then on every
    /// customer-info update until the controller is released.
    public func startSyncingSubscriptionStatus() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.syncSubscriptionStatus()
            guard let stream = self?.billDog.customerInfoStream else { return }
            for await info in stream {
                guard let self = self, !Task.isCancelled else { return }
                await self.apply(info)
            }
        }
    }

    /// Read BillDog's customer info and set Superwall's subscription status.
    ///
    /// When BillDog cannot be read the status is left as it was: a failed
    /// refresh is not evidence that the user lost access.
    public func syncSubscriptionStatus() async {
        guard let info = try? await billDog.getCustomerInfo(forceRefresh: true) else {
            return
        }
        await apply(info)
    }

    /// Superwall entitlement ids for the ACTIVE entitlements in `info`.
    func superwallEntitlementIds(for info: BillDogFull.CustomerInfo) -> Set<String> {
        Set(info.entitlements
            .filter { $0.isActive }
            .map { entitlementMap[$0.identifier] ?? $0.identifier })
    }

    @MainActor
    func apply(_ info: BillDogFull.CustomerInfo) {
        if syncIdentity {
            syncSuperwallIdentity()
        }
        superwall.setActiveEntitlements(superwallEntitlementIds(for: info))
    }

    /// Identify Superwall with BillDog's app user id; reset it when BillDog
    /// goes back to an anonymous user (logout). Anonymous ids are never sent.
    @MainActor
    private func syncSuperwallIdentity() {
        if billDog.isAnonymous {
            if identifiedUserId != nil {
                superwall.reset()
                identifiedUserId = nil
            }
            return
        }
        guard let userId = billDog.appUserId, userId != identifiedUserId else { return }
        superwall.identify(userId: userId)
        identifiedUserId = userId
    }
}
