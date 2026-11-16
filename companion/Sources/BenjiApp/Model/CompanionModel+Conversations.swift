import AppKit
import Combine
import BenjiCore

// MARK: - Saved conversations and the home view

extension CompanionModel {
    private var hearing: Bool { !partialTranscript.isEmpty }
    private var cardPending: Bool { pendingScreenSend != nil || state.pendingApproval != nil }

    /// What the open panel shows below the band: the conversation, home or every saved one.
    var panelPage: PanelPage {
        HomeView.page(requested: history.requestedPage, hasLines: !state.lines.isEmpty, phase: state.phase,
                      hearing: hearing, cardPending: cardPending)
    }

    /// A saved conversation can be opened, or the current one deleted, now.
    var canSwitchConversation: Bool {
        !phoneTaskRunning && HomeView.canSwitchConversation(phase: state.phase, hearing: hearing, cardPending: cardPending)
    }

    func showPage(_ page: PanelPage) {
        history.requestedPage = page
    }

    /// Makes a saved conversation current: its lines in the panel, its exchanges in memory (sent
    /// to the engine with the next message, within the usual budget), the home view closed.
    func openConversation(_ id: String) {
        guard canSwitchConversation else { return }
        if id == history.currentID, !state.lines.isEmpty {
            history.requestedPage = nil
            return
        }
        guard let saved = history.open(id) else { return }
        replaceConversation(lines: saved.lines.map(\.transcriptLine), memory: saved.memory)
    }

    /// Deletes one saved conversation; if it is the open one, the panel starts afresh.
    func deleteConversation(_ id: String) {
        if id == history.currentID {
            guard canSwitchConversation else { return }
            replaceConversation(lines: [], memory: ConversationMemory())
        }
        history.delete(id)
    }

    /// Deletes every saved conversation; the open one leaves the panel too, when nothing runs.
    func deleteAllConversations() {
        if history.currentID != nil, canSwitchConversation {
            replaceConversation(lines: [], memory: ConversationMemory())
        }
        history.deleteAll()
    }

    private func replaceConversation(lines: [TranscriptLine], memory: ConversationMemory) {
        self.memory = memory
        backend.reset()   // the engine forgets the old one; the next message restores this memory
        onHidePointer?()
        statusNote = nil
        if lines.isEmpty { history.startNew() }
        history.requestedPage = nil
        apply(.openConversation(lines))
    }
}
