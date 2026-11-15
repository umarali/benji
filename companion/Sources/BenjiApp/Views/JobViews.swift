import SwiftUI
import AppKit
import BenjiCore

/// The one quiet row for the background job: its title and what it is doing, a
/// button for what the user can do now, and, when it needs an approval, the card's words with the
/// app's own Yes and No (no key answers it). Tapping the title opens the job's thread in the
/// history view; the chevron opens steer, files and next steps.
struct JobRowView: View {
    @ObservedObject var model: CompanionModel
    let job: JobSnapshot
    let a: NotchAccessibility
    @State private var steer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(NotchPalette.tint(tint, a))
                    .frame(width: 18)
                Button { model.openJobThread() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).font(.system(.callout, design: .rounded).weight(.semibold))
                            .foregroundStyle(NotchPalette.label).lineLimit(1).truncationMode(.tail)
                        Text(job.detail).font(.caption).foregroundStyle(NotchPalette.secondary(a))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this job's thread")
                .accessibilityLabel("\(job.title), \(job.state.word). \(job.detail)")
                .accessibilityHint("Opens the job's thread")
                trailing
                Button { model.jobExpanded.toggle() } label: {
                    Image(systemName: model.jobExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchPalette.secondary(a))
                }
                .buttonStyle(.plain)
                .help(model.jobExpanded ? "Hide details" : "Show details")
                .accessibilityLabel(model.jobExpanded ? "Hide job details" : "Show job details")
            }
            if let pending = job.pending {
                approval(pending)
            }
            if job.state == .queued, !job.brief.isEmpty {
                // The start card: what the job was told, while the beat lets the user cancel it.
                Text(job.brief).font(.caption).foregroundStyle(NotchPalette.secondary(a))
                    .lineLimit(4).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("The job was told: \(job.brief)")
            }
            if let schedule = job.schedule {
                scheduleRow(schedule)
            }
            if model.jobExpanded {
                details
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NotchPalette.raised))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch job.state {
        case .queued: return "clock"
        case .working: return "circle.dotted"
        case .needsYou: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        }
    }

    private var tint: NotchTint {
        switch job.state {
        case .queued, .working, .stopped: return .secondary
        case .needsYou: return .approval
        case .done: return .done
        case .failed: return .error
        }
    }

    /// What can be done now: cancel it in its beat, stop it, or clear it once it is over.
    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .queued:
            textButton("Cancel", help: "Cancel before it starts (Esc)") { model.stopJob() }
        case .working, .needsYou:
            textButton("Stop", help: "Stop the job") { model.stopJob() }
        case .done, .failed, .stopped:
            HStack(spacing: 10) {
                if job.offersContinue {
                    textButton("Continue", help: "Another run of this job, picking up from its folder") { model.continueJob() }
                }
                textButton("Clear", help: "Remove the job from the panel") { model.dismissJob() }
            }
        }
    }

    /// A repeating job's schedule: what repeats and when it runs next, and its own buttons.
    /// Repeat runs happen only while Benji is open and the Mac is awake.
    private func scheduleRow(_ schedule: JobSchedule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary(a))
            Text(schedule.rowLine()).font(.caption).foregroundStyle(NotchPalette.secondary(a))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if schedule.canPause {
                textButton("Pause", help: "Stop repeating until you resume it") { model.scheduleJob(.pause) }
            } else {
                textButton("Resume", help: "Repeat again from now") { model.scheduleJob(.resume) }
            }
            textButton("Delete", help: "Stop repeating; the job and its reports stay") { model.scheduleJob(.delete) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repeats: \(schedule.rowLine())")
    }

    private func textButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(NotchPalette.label)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The parked approval: the same words as the card, answered only by these buttons.
    private func approval(_ pending: JobPending) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pending.action).font(.subheadline.weight(.semibold)).foregroundStyle(NotchPalette.label)
                .fixedSize(horizontal: false, vertical: true)
            if !pending.target.isEmpty {
                Text(pending.target).font(NotchFont.mono).foregroundStyle(NotchPalette.secondary(a))
                    .lineLimit(ApprovalPolicy.collapsedTargetLines).truncationMode(.tail).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text("Waits until you answer").font(.caption).foregroundStyle(NotchPalette.secondary(a))
                Spacer(minLength: 0)
                answer("No", approved: false, help: "Don't do it; the job carries on without it")
                answer("Yes", approved: true, help: "Do it")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The job needs approval: \(pending.action). \(pending.target)")
    }

    private func answer(_ title: String, approved: Bool, help: String) -> some View {
        Button { model.answerJob(approved) } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
                .foregroundStyle(approved ? Color.white : NotchPalette.label)
        }
        .approvalButtonStyle(a, prominent: approved)
        .help(help)
        .accessibilityHint(help)
    }

    @ViewBuilder private var details: some View {
        if !job.brief.isEmpty && job.state != .queued {
            VStack(alignment: .leading, spacing: 2) {
                Text("What it was told").font(.caption.weight(.semibold)).foregroundStyle(NotchPalette.secondary(a))
                Text(job.brief).font(.caption).foregroundStyle(NotchPalette.secondary(a))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        ForEach(Array(job.reportBack.enumerated()), id: \.offset) { _, line in
            Text(line).font(.callout).foregroundStyle(NotchPalette.label).fixedSize(horizontal: false, vertical: true)
        }
        if job.unattended {
            Text("Run \(job.run), started by its schedule. Nobody was watching, so it could only read.")
                .font(.caption).foregroundStyle(NotchPalette.secondary(a))
        }
        if let sites = job.sitesLine {
            Label(sites, systemImage: "globe").font(.caption).foregroundStyle(NotchPalette.secondary(a))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityLabel(sites)
        }
        if let acts = job.actSitesLine {
            Label(acts, systemImage: "cursorarrow.click").font(.caption).foregroundStyle(NotchPalette.secondary(a))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityLabel(acts)
        }
        if let line = job.taintLine {
            Text(line).font(.caption).foregroundStyle(NotchPalette.secondary(a))
        }
        if job.state == .working || job.state == .needsYou {
            TextField("Steer this job…", text: $steer)
                .textFieldStyle(.plain).font(.callout).foregroundStyle(NotchPalette.label)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                .onSubmit { if model.steerJob(steer) { steer = "" } }
                .help("Say what to change; it is taken between its steps")
        }
        ForEach(Array(job.files.enumerated()), id: \.offset) { _, file in
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Label(file.name, systemImage: "doc").font(.caption).foregroundStyle(NotchPalette.label)
            }
            .buttonStyle(.plain)
            .help("Show \(file.name) in Finder")
        }
        if job.state != .queued, let folder = JobFolder.url(id: job.id, jobsFolder: AppController.jobsFolder) {
            Button { NSWorkspace.shared.open(folder) } label: {
                Label(JobFolder.buttonTitle, systemImage: "folder").font(.caption).foregroundStyle(NotchPalette.label)
            }
            .buttonStyle(.plain)
            .help(JobFolder.help)
        }
        if !job.chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(job.chips, id: \.self) { chip in
                    Button { model.askJobChip(chip) } label: {
                        Text(chip).font(.caption.weight(.semibold)).foregroundStyle(NotchPalette.label)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
