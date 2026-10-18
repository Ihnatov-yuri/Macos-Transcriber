import SwiftUI

/// "People": voices saved from recordings (Rename speaker → Remember this
/// voice). Each can be renamed or deleted; deleting removes the voice from
/// this Mac and leaves names already in recordings as they are.
struct PeopleSection: View {
    @State private var people = PeopleStore.shared.load()
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var deleting: Person?
    @State private var confirmDeleteAll = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("People")
                .font(AppFont.text(13, weight: .bold))
            Text(people.isEmpty
                 ? "No one saved yet. In a recording, click a speaker's name, type who it is and press Remember this voice. Later recordings then name that person on their own."
                 : "Later recordings name these people on their own. Add someone from a recording: click a speaker's name and press Remember this voice. Saving the same name again adds that recording to their voice.")
                .font(AppFont.text(11))
                .foregroundStyle(AppColor.ink2)
                .frame(maxWidth: 520, alignment: .leading)

            ForEach(people) { person in
                HStack(spacing: AppMetric.m) {
                    if editing == person.id {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onSubmit { commitRename(person) }
                        TapButton { commitRename(person) } label: {
                            LitButtonChrome(.secondary, compact: true) { Text("Save") }
                        }
                    } else {
                        Text(person.name).font(AppFont.text(13))
                        Text(detail(person)).font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                        Spacer()
                        TapButton { editing = person.id; draft = person.name } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("Rename") }
                        }
                        TapButton { deleting = person } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("Delete…") }
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
            }

            if people.count > 1 {
                TapButton { confirmDeleteAll = true } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Delete everyone…") }
                }
            }
            if let error {
                Text(error).font(AppFont.text(11)).foregroundStyle(AppColor.statusError)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PeopleStore.didChange)) { _ in
            people = PeopleStore.shared.load()
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")'s voice?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { person in
            Button("Delete", role: .destructive) { run { try PeopleStore.shared.delete(person.id) } }
        } message: { _ in
            Text("The voice is removed from this Mac. Names already in recordings stay.")
        }
        .confirmationDialog("Delete all \(people.count) saved voices?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { run { try PeopleStore.shared.deleteAll() } }
        }
    }

    private func detail(_ p: Person) -> String {
        let from = p.sources == 1 ? "1 recording" : "\(p.sources) recordings"
        return "\(Int(p.print.seconds)) s from \(from)"
    }

    private func commitRename(_ person: Person) {
        run { try PeopleStore.shared.rename(person.id, to: draft) }
        editing = nil
    }

    private func run(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = error.localizedDescription }
    }
}
