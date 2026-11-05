import HermesGatewayKit
import SwiftUI

/// A13: search the skills hub and install into this bot, each install confirmed first.
struct BotSkillsFinderView: View {
    @ObservedObject var finder: BotSkillsFinderModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                TextField("Search the skills hub", text: $finder.query, prompt: Text("Search the skills hub"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await finder.search() } }
                Button(finder.searching ? "Searching…" : "Search") { Task { await finder.search() } }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(!finder.canSearch)
            }
            if let results = finder.results {
                if results.isEmpty {
                    Text("No skills found.").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            ForEach(results) { row($0) }
                        }
                        .padding(DS.Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: BotEditorLayout.listHeight)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                }
            }
            if let notice = finder.notice {
                Label(notice, systemImage: "checkmark.circle").font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
            }
            BotEditorErrorLine(text: finder.error)
            Text("Installed skills are added to this bot right away and switched on.")
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
        }
        .alert("Install \(finder.confirming?.name ?? "this skill")?",
               isPresented: Binding(get: { finder.confirming != nil }, set: { _ in })) {
            Button("Install") { Task { await finder.confirmInstall() } }
            Button("Cancel", role: .cancel) { finder.cancelInstall() }
        } message: {
            Text("Hermes downloads the skill into @\(finder.profile)'s profile and scans it first. Skills can run commands when the bot uses them.")
        }
    }

    private func row(_ r: SkillsHub.Result) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s0) {
                Text(r.name).font(DS.Typeface.metaStrong).foregroundStyle(DS.Palette.ink).lineLimit(1).truncationMode(.middle)
                if !r.description.isEmpty {
                    Text(r.description).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).lineLimit(2)
                }
            }
            Spacer(minLength: DS.Space.s1)
            if finder.installed.contains(r.name) {
                Label("Installed", systemImage: "checkmark").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
            } else if finder.installing == r.name {
                ProgressView().controlSize(.small)
            } else {
                Button("Install…") { finder.requestInstall(r) }
                    .buttonStyle(.link).font(DS.Typeface.meta)
                    .disabled(finder.installing != nil)
            }
        }
    }
}

/// A14: the bot's MCP servers. The on/off toggles are saved with Save (A9); Add, Set API Key, Test and Sign In act
/// on the profile right away.
struct BotMcpSection: View {
    @ObservedObject var editor: BotEditorModel
    @ObservedObject var mcp: BotMcpModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if editor.mcpServers.isEmpty {
                Text("No MCP servers configured for this bot.").font(DS.Typeface.meta).foregroundStyle(DS.Palette.muted)
            }
            ForEach(editor.mcpServers) { m in serverRow(m) }
            switch mcp.phase {
            case .loading where mcp.servers.isEmpty:
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text("Checking servers…").font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            case .unsupported:
                Text("This Hermes cannot set up MCP servers from the app. Use `hermes mcp`, or update Hermes.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            case .failed(let why):
                HStack(spacing: DS.Space.s2) {
                    BotEditorErrorLine(text: "Could not list the servers: \(why)")
                    Button("Try Again") { Task { await mcp.load() } }.buttonStyle(.link).font(DS.Typeface.meta)
                }
            default:
                EmptyView()
            }
            if mcp.phase == .loaded || mcp.phase == .loading {
                Button(mcp.addOpen ? "Cancel Adding" : "Add Server…") { mcp.toggleAdd() }
                    .buttonStyle(.link).font(DS.Typeface.meta)
                if mcp.addOpen { addForm }
                Text("Add, Set API Key, Test and Sign In change the bot at once; the switches are saved with Save.")
                    .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: rows

    private func serverRow(_ m: BotProfileAPI.Capability) -> some View {
        let info = mcp.server(m.name)
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                Toggle(isOn: Binding(get: { m.enabled }, set: { editor.setMcp(m.name, $0) })) {
                    Text(m.name + Self.detail(m, info)).font(DS.Typeface.meta).foregroundStyle(DS.Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                .help(m.name)
                Spacer(minLength: DS.Space.s1)
                if let info, mcp.phase == .loaded { actions(info) }
            }
            if let busy = mcp.busy[m.name] {
                HStack(spacing: DS.Space.s1) {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                    if mcp.signingIn.contains(m.name) {
                        Button("Cancel") { mcp.cancelSignIn(m.name) }.buttonStyle(.link).font(DS.Typeface.caption)
                    }
                }
            } else if let status = mcp.status[m.name] {
                if status.isError { BotEditorErrorLine(text: status.text) } else {
                    Text(status.text).font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted)
                }
            }
            if mcp.keyServer == m.name { keyForm(m.name, info) }
        }
    }

    static func detail(_ m: BotProfileAPI.Capability, _ info: MCPServers.Server?) -> String {
        guard let info else { return m.detail.map { " · \($0)" } ?? "" }
        var parts = [info.isURL ? "URL" : "command"]
        if info.auth == "oauth" { parts.append(info.oauthTokensPresent == true ? "signed in" : "needs sign-in") }
        if info.auth == "header" { parts.append("API key") }
        return " · " + parts.joined(separator: " · ")
    }

    private func actions(_ s: MCPServers.Server) -> some View {
        HStack(spacing: DS.Space.s2) {
            Button("Test") { Task { await mcp.test(s.name) } }
            Button("API Key…") { mcp.openKey(s.name) }
            if s.canSignIn { Button("Sign In") { Task { await mcp.signIn(s.name) } } }
        }
        .buttonStyle(.link).font(DS.Typeface.meta)
        .disabled(mcp.busy[s.name] != nil)
    }

    private func keyForm(_ name: String, _ info: MCPServers.Server?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                TextField("Variable", text: $mcp.keyEnvVar, prompt: Text(info?.env.first ?? "Variable (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                SecureField("API key", text: $mcp.keyValue, prompt: Text("API key"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await mcp.submitKey() } }
                Button("Save") { Task { await mcp.submitKey() } }.buttonStyle(DSButtonStyle(kind: .secondary))
            }
            Text(info?.isURL == true
                 ? "Sent as a Bearer token. Stored in the bot's .env; config.yaml only refers to it."
                 : "Stored in the bot's .env and passed to the server as that variable (MCP_<NAME>_API_KEY if empty).")
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, DS.Space.s4)
    }

    // MARK: add

    private var addForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Picker("Server type", selection: $mcp.addKind) {
                ForEach(BotMcpModel.AddKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            TextField("Name", text: $mcp.addName, prompt: Text("Name, e.g. github")).textFieldStyle(.roundedBorder)
            if mcp.addKind == .url {
                TextField("URL", text: $mcp.addURL, prompt: Text("https://example.com/mcp")).textFieldStyle(.roundedBorder)
            } else {
                TextField("Command", text: $mcp.addCommand, prompt: Text("Command, e.g. npx")).textFieldStyle(.roundedBorder)
                TextField("Arguments", text: $mcp.addArguments, prompt: Text("Arguments, e.g. -y @scope/server")).textFieldStyle(.roundedBorder)
                TextField("Environment", text: $mcp.addEnvironment, prompt: Text("KEY=VALUE, one per line (no secrets)"), axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: DS.Space.s2) {
                Button(mcp.adding ? "Adding…" : "Add Server") { Task { await mcp.submitAdd() } }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(mcp.adding)
                if mcp.adding { ProgressView().controlSize(.small) }
            }
            BotEditorErrorLine(text: mcp.addError)
            Text("Environment values are written to config.yaml; use API Key… for secrets.")
                .font(DS.Typeface.caption).foregroundStyle(DS.Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.s2)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}
