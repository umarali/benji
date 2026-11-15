import Foundation
import BenjiCore

/// The saved conversations behind the home view: which one is current, the summaries it lists,
/// the page the open panel was asked to show, and the "Save conversations" switch. Files are
/// written and removed on a serial queue, off the main thread, in the order asked.
/// Without a store (tests, offscreen renders) nothing is read or written.
final class ConversationHistory: ObservableObject {
    /// Every saved conversation, newest first.
    @Published private(set) var summaries: [ConversationSummary] = []
    /// The conversation the panel shows and the next message continues; nil until it is saved.
    @Published private(set) var currentID: String?
    /// The page the user asked for; nil lets the panel choose (`HomeView.page`).
    @Published var requestedPage: PanelPage?
    @Published private(set) var saving: Bool

    private let store: ConversationStore?
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "benji.conversations", qos: .utility)
    /// What was last written for the current conversation (nothing is written twice).
    private var lastSaved: [SavedLine] = []
    private var started: Date?

    init(store: ConversationStore?, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        saving = MemorySettings.savesConversations(defaults.object(forKey: MemorySettings.saveKey))
        reload()
    }

    /// Reads the folder again (at launch, and after a deletion that may have failed part way).
    func reload() {
        guard let store else { return }
        queue.async { [weak self] in
            let all = store.list()
            DispatchQueue.main.async { self?.summaries = all }
        }
    }

    /// The panel's lines changed: save the current conversation when it has something new and an
    /// answer, under its id (a new one the first time).
    func record(_ transcript: [TranscriptLine], now: Date = Date()) {
        guard saving, let store else { return }
        let lines = SavedConversation.lines(from: transcript)
        guard lines != lastSaved, SavedConversation.worthSaving(lines) else { return }
        let id = currentID ?? ConversationStore.newID()
        if currentID != id { currentID = id }
        // The one just used is always the newest, even within a millisecond of another.
        // Snapped to the millisecond a saved record keeps, so the order survives the round trip.
        let now = ConversationStore.saveTime(now, after: summaries.first(where: { $0.id != id })?.updated)
        let start = started ?? now
        started = start
        lastSaved = lines
        let record = SavedConversation(id: id, title: ConversationTitle.make(lines), started: start, updated: now,
                                       lines: lines)
        summaries = ([record.summary] + summaries.filter { $0.id != id }).sorted(by: ConversationSummary.newestFirst)
        queue.async { try? store.save(record) }
    }

    /// A background job's thread, under the job's id: listed and opened like any
    /// conversation, without becoming the current one. Not rewritten while it is the open one (the
    /// user continued it), so what they added isn't lost.
    func saveJob(_ conversation: SavedConversation) {
        guard saving, let store, conversation.id != currentID else { return }
        summaries = ([conversation.summary] + summaries.filter { $0.id != conversation.id })
            .sorted(by: ConversationSummary.newestFirst)
        queue.async { try? store.save(conversation) }
    }

    /// New conversation: the next answer starts a new file.
    func startNew() {
        currentID = nil
        lastSaved = []
        started = nil
    }

    /// Reads a saved conversation and makes it the current one.
    func open(_ id: String) -> SavedConversation? {
        guard let store else { return nil }
        queue.sync {}   // a write still queued for it lands first
        guard let saved = store.load(id) else {
            summaries.removeAll { $0.id == id }   // gone from the folder since it was listed
            return nil
        }
        currentID = id
        lastSaved = saved.lines
        started = saved.started
        return saved
    }

    /// Removes one conversation's file. The current one stops being saved under it.
    func delete(_ id: String) {
        if id == currentID { startNew() }
        summaries.removeAll { $0.id == id }
        guard let store else { return }
        queue.async { [weak self] in
            do { try store.delete(id) } catch { self?.reload() }
        }
    }

    /// Removes every saved conversation's file.
    func deleteAll() {
        startNew()
        summaries = []
        guard let store else { return }
        queue.async { [weak self] in
            do { try store.deleteAll() } catch { self?.reload() }
        }
    }

    /// Off: nothing more is written (what is saved stays until deleted). On again: the current
    /// conversation is saved from its next change.
    func setSaving(_ on: Bool) {
        defaults.set(on, forKey: MemorySettings.saveKey)
        saving = on
        if !on { lastSaved = [] }
    }

    /// Waits for queued writes and deletions (tests, and before quitting).
    func flush() { queue.sync {} }
}
