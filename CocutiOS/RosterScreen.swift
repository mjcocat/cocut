import SwiftUI

/// The team's jersey numbers and names. Find Rallies lists only these numbers on rallies, so
/// opponents and misreads are left out; clips read "#11 Lilah".
struct RosterScreen: View {
    @Environment(IOSModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var name = ""
    @FocusState private var numberFocused: Bool

    var body: some View {
        let library = model.library
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("#", text: $number)
                            .keyboardType(.numberPad)
                            .frame(width: 56)
                            .focused($numberFocused)
                        TextField("Name (optional)", text: $name)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(Int(number) == nil)
                    }
                } footer: {
                    Text("Only roster numbers are listed on rallies, so opponents, referees and misreads are left out.")
                }
                if !library.roster.isEmpty {
                    Section("\(library.roster.count) players") {
                        ForEach(library.roster) { player in
                            HStack {
                                Text("#\(player.number)").monospacedDigit().frame(width: 48, alignment: .leading)
                                Text(player.name.isEmpty ? "No name" : player.name)
                                    .foregroundStyle(player.name.isEmpty ? .secondary : .primary)
                            }
                        }
                        .onDelete { offsets in
                            for number in offsets.map({ library.roster[$0].number }) { library.removePlayer(number) }
                        }
                    }
                }
            }
            .navigationTitle("Team Roster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { numberFocused = library.roster.isEmpty }
        }
    }

    private func add() {
        guard let n = Int(number.trimmingCharacters(in: .whitespaces)) else { return }
        model.library.addPlayer(number: n, name: name)
        number = ""
        name = ""
        numberFocused = true
    }
}
