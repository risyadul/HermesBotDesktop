import AppKit
import HermesGatewayKit
import SwiftUI

/// E2 first-run screens (Onboarding.swift decides which): the `empty-state` pattern (symbol, heading, one
/// sentence) plus the commands that fix the state, each with a Copy button. Commands are shown and copied,
/// never run by the app.
struct OnboardingView: View {
    let screen: OnboardingScreen
    var onTryAgain: () -> Void = {}
    var onCheckAgain: () -> Void = {}
    var onOpenBot: (String) -> Void = { _ in }
    @State private var botName = Onboarding.suggestedBotName

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.s3) {
                Image(systemName: symbol)
                    .font(DS.Typeface.symbolEmpty).foregroundStyle(DS.Palette.muted)
                    .padding(.bottom, DS.Space.s1)
                    .accessibilityHidden(true)
                Text(title).font(DS.Typeface.titleState).foregroundStyle(DS.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(DS.Typeface.body).foregroundStyle(DS.Palette.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                content.padding(.top, DS.Space.s2)
            }
            .frame(maxWidth: Self.width)
            .padding(DS.Space.s6)
            .frame(maxWidth: .infinity, minHeight: DS.Size.emptyRoomMinHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    static let width: CGFloat = 440

    private var symbol: String {
        switch screen {
        case .hermesMissing: return "shippingbox"
        case .noModel: return "cpu"
        case .oneBot: return "person.2"
        }
    }

    private var title: String {
        switch screen {
        case .hermesMissing: return "Install Hermes Agent"
        case .noModel: return "Choose a model for Hermes"
        case .oneBot(_, let title): return "Chat with \(title)"
        }
    }

    private var message: String {
        switch screen {
        case .hermesMissing(_, let problem?):
            return "\(Onboarding.overrideVariable) can't be used: \(problem)."
        case .hermesMissing:
            return "Hermes Bot works with Hermes Agent on this Mac, and no hermes program was found."
        case .noModel(let provider, _, let reason):
            let why = reason ?? provider.map { "No usable credentials found for \($0)." } ?? "No provider is set up."
            return "Hermes is running but can't reply yet. \(why)"
        case .oneBot:
            return "Bot Chat works with one bot. Group Chat needs at least two: each Hermes profile is a bot."
        }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .hermesMissing(let tried, _):
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                step("Install Hermes Agent and set up a model, then press Try Again.")
                step("Installed somewhere else? Start the app from a terminal with its full path:")
                CommandRow(command: Onboarding.overrideExample)
                if !tried.isEmpty {
                    DisclosureGroup("Places checked") {
                        VStack(alignment: .leading, spacing: DS.Space.s0) {
                            ForEach(tried, id: \.self) { Text($0).font(DS.Typeface.code) }
                        }
                        .foregroundStyle(DS.Palette.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Space.s1)
                    }
                    .font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                }
                actions {
                    Link("Hermes Agent Docs", destination: Onboarding.docsURL).buttonStyle(DSButtonStyle(kind: .secondary))
                    Button("Try Again", action: onTryAgain).buttonStyle(DSButtonStyle(kind: .primary))
                }
            }
        case .noModel(_, let model, _):
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                if let model { step("Model it would use: \(model)") }
                step("Set up a provider and model in Terminal, then press Check Again:")
                CommandRow(command: Onboarding.modelCommands[0], note: "guided setup")
                CommandRow(command: Onboarding.modelCommands[1], note: "provider and model only")
                actions {
                    Link("Hermes Agent Docs", destination: Onboarding.docsURL).buttonStyle(DSButtonStyle(kind: .secondary))
                    Button("Check Again", action: onCheckAgain).buttonStyle(DSButtonStyle(kind: .primary))
                }
            }
        case .oneBot(let name, _):
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                HStack {
                    Spacer()
                    Button("Open Bot Chat") { onOpenBot(name) }.buttonStyle(DSButtonStyle(kind: .primary))
                    Spacer()
                }
                Hairline().padding(.vertical, DS.Space.s2)
                Text("Add a second bot").font(DS.Typeface.bodyStrong).foregroundStyle(DS.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: DS.Space.s2) {
                    Text("Name").font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink)
                    TextField("Name", text: $botName).textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityLabel("New bot name")
                }
                if let commands = Onboarding.newBotCommands(name: botName) {
                    step("Run these in Terminal, then press Check Again:")
                    CommandRow(command: commands[0], note: "creates the bot")
                    CommandRow(command: commands[1], note: "gives it a provider and model")
                } else {
                    Text("Use lowercase letters, digits, - and _ (not \"default\").")
                        .font(DS.Typeface.meta).foregroundStyle(DS.Palette.danger)
                }
                actions {
                    Button("Check Again", action: onCheckAgain).buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
        }
    }

    private func step(_ text: String) -> some View {
        Text(text).font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func actions<A: View>(@ViewBuilder _ buttons: () -> A) -> some View {
        HStack(spacing: DS.Space.s2) {
            Spacer()
            buttons()
        }
        .padding(.top, DS.Space.s1)
    }
}

/// One command in a code box with a Copy button (the Copy icon turns into a check for a moment).
struct CommandRow: View {
    let command: String
    var note: String?
    @State private var copied = false

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Text(command).font(DS.Typeface.code).foregroundStyle(DS.Palette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted) }
            }
            Spacer(minLength: 0)
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: "Copy \(command)") {
                CommandRow.copy(command)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
        }
        .padding(.leading, DS.Space.s3).padding(.trailing, DS.Space.s1).padding(.vertical, DS.Space.s1)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .strokeBorder(DS.Palette.hairline, lineWidth: DS.Stroke.hairline))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
