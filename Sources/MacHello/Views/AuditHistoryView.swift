import SwiftUI
import AppKit
import MacHelloCore

public struct AuditHistoryView: View {
    @ObservedObject private var logger = AuthAuditLogger.shared
    @State private var selectedRecordId: String?
    @State private var showClearConfirm: Bool = false

    var onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    private var selectedRecord: AuditRecord? {
        if let id = selectedRecordId {
            return logger.records.first(where: { $0.id == id })
        }
        return logger.records.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("人脸解锁与通行抓拍历史")
                        .font(.headline)
                    Text("记录每次锁屏唤醒、人脸感应亮屏、管理员弹窗与终端 Sudo 的真实实况")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("完成") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if logger.records.isEmpty {
                // 空状态视图
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "camera.badge.clock")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("暂无通行抓拍历史")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("当您进行锁屏 Face ID 解锁、离开后靠近自动亮屏、或在终端中使用 sudo 时，系统会自动在此留存实拍图。")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 主内容区：左侧历史列表 + 右侧详情大图
                HSplitView {
                    // 左侧：历史记录列表
                    List(selection: $selectedRecordId) {
                        ForEach(logger.records) { record in
                            HStack(spacing: 10) {
                                Image(systemName: record.displayIcon)
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(record.displayTitle)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text(String(format: "%.0f%%", record.score * 100))
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.15))
                                            .cornerRadius(4)
                                    }

                                    Text(record.timestamp, style: .date)
                                        + Text(" ")
                                        + Text(record.timestamp, style: .time)
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .tag(record.id)
                        }
                    }
                    .frame(minWidth: 260, maxWidth: 300)

                    // 右侧：单条详情与实拍照片
                    if let record = selectedRecord {
                        VStack(spacing: 16) {
                            // 实拍图像显示
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black)
                                    .frame(height: 300)

                                if let img = logger.loadImage(for: record) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 290)
                                        .cornerRadius(8)
                                } else {
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundColor(.secondary)
                                        Text("图像文件不存在或已被移除")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 16)

                            // 识别指标参数
                            VStack(spacing: 8) {
                                detailRow(title: "通行事件", value: record.displayTitle)
                                detailRow(title: "人脸相似度", value: String(format: "%.1f%% (安全门限: 58.0%%)", record.score * 100))
                                detailRow(title: "核验状态", value: record.success ? "机主本人·验证通过 ✓" : "未通过")
                                detailRow(title: "抓拍时间", value: formatDate(record.timestamp))
                            }
                            .padding(12)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                            .cornerRadius(8)
                            .padding(.horizontal, 20)

                            HStack {
                                Button(role: .destructive, action: {
                                    logger.deleteRecord(id: record.id)
                                    if selectedRecordId == record.id {
                                        selectedRecordId = logger.records.first?.id
                                    }
                                }) {
                                    Label("删除此条抓拍", systemImage: "trash")
                                }
                                .font(.caption)

                                Spacer()
                            }
                            .padding(.horizontal, 20)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            Divider()

            // 底部工具栏
            HStack(spacing: 12) {
                Button("📂 打开本地相册文件夹") {
                    logger.openHistoryFolder()
                }
                .font(.subheadline)

                Spacer()

                if !logger.records.isEmpty {
                    Text("共 \(logger.records.count) 条通行抓拍记录")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("清空全部记录") {
                        showClearConfirm = true
                    }
                    .font(.subheadline)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 680, height: 540)
        .alert(isPresented: $showClearConfirm) {
            Alert(
                title: Text("清空所有通行抓拍历史？"),
                message: Text("此操作将永久删除保存在 ~/.machello/history/ 下的所有实拍图片与记录。"),
                primaryButton: .destructive(Text("确认清空")) {
                    logger.clearAllRecords()
                    selectedRecordId = nil
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear {
            logger.loadRecords()
            if selectedRecordId == nil {
                selectedRecordId = logger.records.first?.id
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
