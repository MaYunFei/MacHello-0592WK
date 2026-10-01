import SwiftUI
import AppKit
import MacHelloCore

public struct AuditHistoryView: View {
    @ObservedObject private var logger = AuthAuditLogger.shared
    @ObservedObject private var lang = LanguageManager.shared
    @State private var selectedRecordId: String?
    @State private var filterMode: AuditFilter = .all
    @State private var showClearConfirm: Bool = false

    enum AuditFilter: String, CaseIterable, Identifiable {
        case all
        case passed
        case failed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return loc("All", "全部")
            case .passed: return loc("Passed", "验证通过")
            case .failed: return loc("Failed", "未通过")
            }
        }
    }

    var onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private var filteredRecords: [AuditRecord] {
        switch filterMode {
        case .all:
            return logger.records
        case .passed:
            return logger.records.filter { $0.success }
        case .failed:
            return logger.records.filter { !$0.success }
        }
    }

    private var selectedRecord: AuditRecord? {
        if let id = selectedRecordId {
            return filteredRecords.first(where: { $0.id == id }) ?? filteredRecords.first
        }
        return filteredRecords.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            headerToolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if logger.records.isEmpty {
                // 空数据全屏提示
                emptyStateView
            } else {
                // 主内容区：左右分栏
                HSplitView {
                    // 左侧：事件列表
                    recordsListView
                        .frame(minWidth: 280, maxWidth: 320)

                    // 右侧：单条实况快照与安全审计面板
                    detailInspectorView
                        .frame(minWidth: 420)
                }
            }

            Divider()

            // 底部状态与管理栏
            bottomToolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 760, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .alert(isPresented: $showClearConfirm) {
            Alert(
                title: Text(loc("Clear All Access History?", "清空所有通行抓拍历史？")),
                message: Text(loc("This permanently deletes all snapshots and history in ~/.machello/history/.", "此操作将永久删除保存在 ~/.machello/history/ 下的所有实况照片与历史记录。")),
                primaryButton: .destructive(Text(loc("Confirm", "确认清空"))) {
                    logger.clearAllRecords()
                    selectedRecordId = nil
                },
                secondaryButton: .cancel(Text(loc("Cancel", "取消")))
            )
        }
        .onAppear {
            logger.loadRecords()
            if selectedRecordId == nil {
                selectedRecordId = filteredRecords.first?.id
            }
        }
        .onChange(of: filterMode) { _ in
            selectedRecordId = filteredRecords.first?.id
        }
    }

    // MARK: - 顶部工具栏
    private var headerToolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(loc("Face ID Access & Snapshot History", "人脸解锁与通行抓拍历史"))
                    .font(.headline)
                    .fontWeight(.bold)
                Text(loc("Biometric verification logs & snapshots", "实况留存与生物特征核验记录"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !logger.records.isEmpty {
                Picker(loc("Filter", "筛选"), selection: $filterMode) {
                    ForEach(AuditFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }

            Button(loc("Done", "完成")) {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - 左侧历史记录列表
    private var recordsListView: some View {
        VStack(spacing: 0) {
            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(loc("No records under current filter", "当前筛选下无记录"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(selection: $selectedRecordId) {
                    ForEach(filteredRecords) { record in
                        recordRow(record)
                            .tag(record.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func recordRow(_ record: AuditRecord) -> some View {
        HStack(spacing: 10) {
            // 图标方块
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(eventColor(for: record.reason).opacity(0.12))
                    .frame(width: 28, height: 28)

                Image(systemName: record.displayIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(eventColor(for: record.reason))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.displayTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    Text(String(format: "%.0f%%", record.score * 100))
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(record.success ? .green : .orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background((record.success ? Color.green : Color.orange).opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(formatTimestamp(record.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - 右侧详情面板
    private var detailInspectorView: some View {
        Group {
            if let record = selectedRecord {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 实拍图像显示卡片
                        snapshotImageCard(record)

                        // 安全审计指标卡片
                        securityMetricsCard(record)

                        // 快捷动作栏
                        recordActionButtons(record)
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(loc("Select a record on the left to inspect", "请在左侧选择要查看的通行记录"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.2))
    }

    private func snapshotImageCard(_ record: AuditRecord) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.9))
                .frame(height: 250)

            if let img = logger.loadImage(for: record) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 242)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.3))
                    Text(loc("Snapshot image not found or removed", "图像文件不存在或已被清除"))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
    }

    private func securityMetricsCard(_ record: AuditRecord) -> some View {
        VStack(spacing: 10) {
            metricRow(title: loc("Event", "通行事件"), value: record.displayTitle, icon: record.displayIcon)

            // 相似度指示器
            VStack(spacing: 4) {
                HStack {
                    Label(loc("Face Similarity", "人脸相似度"), systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%  (\(loc("Threshold", "安全阈值")): 58.0%%)", record.score * 100))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(record.success ? .green : .orange)
                }

                // 微型进度条对比
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 5)

                        Capsule()
                            .fill(record.success ? Color.green : Color.orange)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(record.score))), height: 5)

                        // 58% 阈值参考线
                        Rectangle()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 2, height: 9)
                            .offset(x: geo.size.width * 0.58 - 1)
                    }
                }
                .frame(height: 9)
            }

            Divider()

            metricRow(
                title: loc("Security Decision", "安全判定"),
                value: record.success
                    ? loc("Owner Verified ✓", "机主本人 • 验证通过 ✓")
                    : loc("Threshold Not Met • Access Denied", "相似度未达标 • 拒绝通行"),
                icon: record.success ? "checkmark.shield.fill" : "xmark.shield.fill",
                valueColor: record.success ? .green : .red
            )

            metricRow(
                title: loc("Captured At", "抓拍时间"),
                value: formatDateLong(record.timestamp),
                icon: "clock.fill"
            )
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.25), lineWidth: 1)
        )
    }

    private func recordActionButtons(_ record: AuditRecord) -> some View {
        HStack {
            Button(action: {
                let fileURL = logger.historyDirectory.appendingPathComponent(record.filename)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }) {
                Label(loc("Reveal in Finder", "在访达中显示"), systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .font(.caption)

            Spacer()

            Button(role: .destructive, action: {
                logger.deleteRecord(id: record.id)
                if selectedRecordId == record.id {
                    selectedRecordId = filteredRecords.first?.id
                }
            }) {
                Label(loc("Delete Record", "删除此条记录"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "camera.badge.clock")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 6) {
                Text(loc("No Access History Yet", "暂无通行抓拍历史"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(loc(
                    "When you unlock your Mac, wake the screen via presence, or run sudo in Terminal,\nverification snapshots will be securely saved here.",
                    "当您进行锁屏 Face ID 解锁、感应亮屏、或终端中使用 sudo 提权时，\n系统会自动在此安全留存核验快照。"
                ))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部工具栏
    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            Button(action: {
                logger.openHistoryFolder()
            }) {
                Label(loc("Open History Folder", "打开历史相册文件夹"), systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .font(.subheadline)

            Spacer()

            if !logger.records.isEmpty {
                Text(loc("\(logger.records.count) records", "共 \(logger.records.count) 条记录"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(loc("Clear History", "清空记录")) {
                    showClearConfirm = true
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - 辅助组件
    private func metricRow(title: String, value: String, icon: String, valueColor: Color = .primary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
        }
    }

    private func eventColor(for reason: String) -> Color {
        switch reason {
        case "lockscreen": return .green
        case "wake_display": return .blue
        case "admin_prompt": return .purple
        case "terminal_sudo": return .orange
        case "diagnostic": return .cyan
        default: return .secondary
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm:ss"
            return "\(loc("Today", "今天")) \(formatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm:ss"
            return "\(loc("Yesterday", "昨天")) \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    private func formatDateLong(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
