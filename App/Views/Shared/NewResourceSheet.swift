import SwiftUI

/// Shared scaffolding for the "create a named resource with a driver and
/// optional labels" sheets (volumes, networks). Callers supply the title, the
/// driver control (a free text field or a picker), and the async create action;
/// the name field, label editor, working state, and Cancel/Create footer are
/// shared.
struct NewResourceSheet<DriverControl: View>: View {
    let title: String
    @ViewBuilder let driverControl: (Binding<String>) -> DriverControl
    /// Performs the creation; returns `true` on success (the sheet then dismisses).
    let create: (_ name: String, _ driver: String, _ labels: [String: String]) async -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var driver: String
    @State private var labels: [LabelPair] = []
    @State private var working = false

    init(
        title: String,
        defaultDriver: String,
        @ViewBuilder driverControl: @escaping (Binding<String>) -> DriverControl,
        create: @escaping (_ name: String, _ driver: String, _ labels: [String: String]) async -> Bool
    ) {
        self.title = title
        self.driverControl = driverControl
        self.create = create
        _driver = State(initialValue: defaultDriver)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                driverControl($driver)
                LabelEditor(pairs: $labels)
            }
            .disabled(working)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        working = true
        let nameValue = name.trimmingCharacters(in: .whitespaces)
        let labelDict = labels.asDictionary
        Task {
            let ok = await create(nameValue, driver, labelDict)
            working = false
            if ok { dismiss() }
        }
    }
}
