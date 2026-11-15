import SwiftUI

struct MagicTasksView: View {
    @ObservedObject var agent: ConnectionClient
    @ObservedObject var store: NotebookStore
    var body: some View {
        NavigationStack {
            List {
                if agent.jobs.isEmpty {
                    ContentUnavailableView("No tasks yet", systemImage: "sparkles", description: Text("Each request keeps its own reference. You can run up to four tasks while you keep writing."))
                }
                ForEach(agent.jobs.reversed()) { job in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top) {
                            if job.state == .running { ProgressView().controlSize(.small) }
                            else { Image(systemName: icon(job.state)).foregroundStyle(job.state == .failed ? Color.orange : Color.secondary) }
                            Text(job.prompt).font(.subheadline.weight(.medium)).lineLimit(3)
                            Spacer(minLength: 0)
                            if job.state == .running {
                                Button { agent.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).accessibilityLabel("Cancel task")
                            }
                        }
                        Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                        if job.state == .completed, !job.resultIDs.isEmpty, job.notebookID == store.notebook.id {
                            Button("Show result", systemImage: "scope") { agent.focus(job, store: store) }.font(.caption).buttonStyle(.borderless)
                        }
                        Text(job.startedAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
                    }.padding(.vertical, 5)
                }
            }.navigationTitle("Tasks").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Clear finished") { agent.dismissFinishedJobs() }.font(.caption) }
        }
    }
    private func icon(_ state: CanvasAgentJob.State) -> String {
        switch state {
        case .running: return "ellipsis.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }
}
