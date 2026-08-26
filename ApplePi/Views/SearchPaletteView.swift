import SwiftUI

struct SearchPaletteView: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = model.searchProjection(query: query)
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                palette(results)
                    .padding(.top, max(64, min(130, proxy.size.height * 0.14)))
            }
        }
        .ignoresSafeArea()
        .onExitCommand(perform: dismiss)
    }

    private func palette(_ results: ApplePiSearchProjection) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search projects and tasks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .accessibilityIdentifier("applepi.search-field")
                    .onSubmit { openFirstResult(in: results) }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if results.projectResults.isEmpty && results.taskResults.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 42)
                    } else {
                        if !results.projectResults.isEmpty {
                            resultSection("Projects", results: results.projectResults)
                        }

                        if !results.taskResults.isEmpty {
                            resultSection(results.queryIsEmpty ? "Recent tasks" : "Tasks", results: results.taskResults)
                        }
                    }

                }
                .padding(14)
            }
        }
        .frame(width: 620, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.65), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 16)
        .task {
            await Task.yield()
            searchFocused = true
        }
    }

    @ViewBuilder
    private func resultSection(_ title: String, results: [ApplePiSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title)

            ForEach(results) { result in
                Button {
                    open(result)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: result.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 12)

                        if let context = result.context {
                            Text(context)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(SearchPaletteRowButtonStyle())
                .accessibilityIdentifier(result.accessibilityIdentifier)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func openFirstResult(in results: ApplePiSearchProjection) {
        guard let firstResult = results.projectResults.first ?? results.taskResults.first else { return }
        open(firstResult)
    }

    private func open(_ result: ApplePiSearchResult) {
        model.selection = result.destination
        dismiss()
    }

    private func dismiss() {
        isPresented = false
    }
}

private struct SearchPaletteRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : 0))
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}
