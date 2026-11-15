import AppKit
import Combine
import BenjiCore

extension CompanionModel {
    // MARK: app offers

    /// Nothing else has the notch, so an offer may appear (or, if showing, may stay).
    var appOfferMomentIsFree: Bool {
        AppOfferRules.momentIsFree(phase: state.phase, panelOpen: expanded, conversationOn: conversationOn,
                                   jobLive: job?.state.isLive ?? false, jobPeek: jobPeek)
    }

    func showAppOffer(_ offer: AppOffer) {
        guard appOffer == nil, appOfferMomentIsFree else { return }
        appOffer = offer
    }

    /// `example`: the row the user picked; Try it alone uses the first. Nothing is sent from here:
    /// the words wait in the message box for the user's Return.
    func answerAppOffer(_ answer: AppOfferAnswer, example: String? = nil) {
        guard let offer = appOffer else { return }
        appOffer = nil
        onAppOfferAnswered?(offer, answer)
        guard answer == .tryIt else { return }
        composerText = example ?? offer.examples.first ?? ""
        onOpenForTyping?()
    }

    /// Something else wants the notch: an offer that's showing steps aside, as if waited out.
    func withdrawAppOfferIfBusy() {
        if appOffer != nil && !appOfferMomentIsFree { answerAppOffer(.notNow) }
    }
}
