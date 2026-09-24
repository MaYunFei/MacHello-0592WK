import SwiftUI
import AppKit
import MacHelloCore

final class EnrollmentViewModel: ObservableObject, FaceEnrollmentDelegate {
    @Published var previewImage: CGImage?
    @Published var stage: EnrollmentStage = .regular
    @Published var targetPose: TargetPose = .center
    @Published var completedPoses: Set<TargetPose> = []
    @Published var progress: Double = 0.0
    @Published var instruction: String = "👀 请正视摄像头，保持平视"
    @Published var isMatchingCurrentPose: Bool = false
    @Published var isPoseFrozen: Bool = false
    @Published var showAlternativePrompt: Bool = false
    @Published var isFinished: Bool = false
    @Published var totalSamplesCount: Int = 0
    @Published var errorMessage: String?

    private let service = FaceEnrollmentService.shared

    init() {
        service.delegate = self
    }

    func start() {
        isFinished = false
        showAlternativePrompt = false
        completedPoses.removeAll()
        progress = 0.0

        do {
            try service.startEnrollment(stage: .regular)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        service.stopEnrollment()
    }

    func startAlternative() {
        showAlternativePrompt = false
        completedPoses.removeAll()
        do {
            try service.startAlternativeStage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func skipAlternative() {
        showAlternativePrompt = false
        service.skipAlternativeStage()
    }

    // MARK: - FaceEnrollmentDelegate

    func enrollmentDidUpdateInstruction(stage: EnrollmentStage, pose: TargetPose, progress: Double, message: String) {
        DispatchQueue.main.async {
            self.stage = stage
            self.targetPose = pose
            self.progress = progress
            self.instruction = message
        }
    }

    func enrollmentDidCapturePose(stage: EnrollmentStage, pose: TargetPose) {
        DispatchQueue.main.async {
            self.completedPoses.insert(pose)
        }
    }

    func enrollmentPoseDidFreeze(stage: EnrollmentStage, pose: TargetPose, isFreezing: Bool) {
        DispatchQueue.main.async {
            self.isPoseFrozen = isFreezing
        }
    }

    func enrollmentStageDidComplete(stage: EnrollmentStage) {
        DispatchQueue.main.async {
            if stage == .regular {
                self.showAlternativePrompt = true
            }
        }
    }

    func enrollmentDidFinishAll(totalSamples: Int) {
        DispatchQueue.main.async {
            self.totalSamplesCount = totalSamples
            self.isFinished = true
        }
    }

    func enrollmentDidFail(error: String) {
        DispatchQueue.main.async {
            self.errorMessage = error
        }
    }

    func enrollmentDidOutputPreview(image: CGImage, stage: EnrollmentStage, currentPose: TargetPose?, isMatching: Bool, faceBoundingBox: CGRect?) {
        DispatchQueue.main.async {
            self.previewImage = image
            self.isMatchingCurrentPose = isMatching
        }
    }
}

struct FaceEnrollmentView: View {
    @StateObject private var viewModel = EnrollmentViewModel()
    var onDismiss: (() -> Void)?

    var body: some View {
        ZStack {
            // 背景暗色材质
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            if viewModel.isFinished {
                // 完成界面
                successView
            } else if viewModel.showAlternativePrompt {
                // 替用外貌提示卡片
                alternativePromptView
            } else {
                // 主录入引导视图
                enrollmentMainView
            }
        }
        .frame(width: 480, height: 560)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    // MARK: - 主录入界面
    private var enrollmentMainView: some View {
        VStack(spacing: 20) {
            // 顶部阶段指示
            HStack {
                Text(viewModel.stage == .regular ? "步骤 1/2：日常 / 佩戴眼镜外观" : "步骤 2/2：脱镜 / 替用外观")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: {
                    viewModel.cancel()
                    onDismiss?()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()

            // 核心环形扫描器与实时红外预览
            ZStack {
                // 1. 动态四段圆环 (上、下、左、右)
                FaceIDProgressRing(
                    completedPoses: viewModel.completedPoses,
                    currentPose: viewModel.targetPose,
                    isMatching: viewModel.isMatchingCurrentPose
                )
                .frame(width: 250, height: 250)

                // 2. 内部红外实时视频镜面预览
                if let cgImage = viewModel.previewImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(x: -1, y: 1) // 水平镜像翻转，符合照镜子习惯
                        .frame(width: 220, height: 220)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                } else {
                    Circle()
                        .fill(Color.black.opacity(0.8))
                        .frame(width: 220, height: 220)
                        .overlay(
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("启动红外摄像头...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        )
                }

                // 3. 匹配时的高亮发光环 (采用平滑不透明度渐变，杜绝节点反复创建/销毁引发的 UI 闪烁)
                Circle()
                    .stroke(Color.green.opacity(0.8), lineWidth: 4)
                    .frame(width: 224, height: 224)
                    .blur(radius: 2)
                    .opacity(viewModel.isMatchingCurrentPose ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.25), value: viewModel.isMatchingCurrentPose)

                // 4. 定格成功浮层微标
                if viewModel.isPoseFrozen {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                            .shadow(color: .black.opacity(0.7), radius: 6)
                        Text("角度已捕获")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 4)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }

            Spacer()

            // 底部指示文案 (ZStack 固定高度布局，杜绝高度/文字突变跳动导致的闪烁)
            VStack(spacing: 10) {
                Text(viewModel.instruction)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .foregroundColor(viewModel.isMatchingCurrentPose ? .green : .primary)
                    .animation(.easeInOut(duration: 0.25), value: viewModel.isMatchingCurrentPose)

                ZStack {
                    Text(viewModel.isPoseFrozen ? "✅ 角度捕获成功，定格中..." : "✓ 保持当前姿势，正在提取特征...")
                        .font(.subheadline)
                        .foregroundColor(.green)
                        .opacity((viewModel.isMatchingCurrentPose || viewModel.isPoseFrozen) ? 1.0 : 0.0)

                    Text("请缓慢转动面部，配合指示")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .opacity((!viewModel.isMatchingCurrentPose && !viewModel.isPoseFrozen) ? 1.0 : 0.0)
                }
                .animation(.easeInOut(duration: 0.25), value: viewModel.isMatchingCurrentPose)
                .animation(.easeInOut(duration: 0.25), value: viewModel.isPoseFrozen)
            }
            .frame(height: 60)

            // 进度条
            ProgressView(value: viewModel.progress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
        }
    }

    // MARK: - 替用外观询问界面
    private var alternativePromptView: some View {
        VStack(spacing: 24) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 54))
                .foregroundColor(.accentColor)
                .padding(.top, 40)

            VStack(spacing: 8) {
                Text("第一阶段录入完成！")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("建议添加【脱镜 / 替用外貌】")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            Text("如果您平时戴眼镜，请摘下眼镜再录入一次。\n这样无论您是否佩戴眼镜，Mac 都能快速识别并秒解。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 36)

            Spacer()

            VStack(spacing: 12) {
                Button(action: {
                    viewModel.startAlternative()
                }) {
                    Text("摘下眼镜并开始录入")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    viewModel.skipAlternative()
                }) {
                    Text("跳过此步 (平时不戴眼镜)")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 36)
        }
    }

    // MARK: - 录入完成界面
    private var successView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
                .padding(.top, 60)

            VStack(spacing: 8) {
                Text("面容 ID 已设置完成")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("已提取并存储 \(viewModel.totalSamplesCount) 组红外 3D 特征向量")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("现在您可以使用戴尔 0592WK 摄像头\n进行人脸感应亮屏与近红外活体解锁。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: {
                onDismiss?()
            }) {
                Text("完成")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 48)
            .padding(.bottom, 36)
        }
    }
}

// MARK: - iPhone 风格四段式环形进度指示器
struct FaceIDProgressRing: View {
    let completedPoses: Set<TargetPose>
    let currentPose: TargetPose
    let isMatching: Bool

    var body: some View {
        ZStack {
            // 背景底环
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 10)

            // 1. 上段 (微微抬头: 45° ~ 135°)
            ArcSegment(startAngle: .degrees(225), endAngle: .degrees(315))
                .stroke(segmentColor(for: .tiltUp), style: StrokeStyle(lineWidth: 10, lineCap: .round))

            // 2. 下段 (正视镜头: 225° ~ 315°)
            ArcSegment(startAngle: .degrees(45), endAngle: .degrees(135))
                .stroke(segmentColor(for: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))

            // 3. 左段 (向左微转: 135° ~ 225°)
            ArcSegment(startAngle: .degrees(135), endAngle: .degrees(225))
                .stroke(segmentColor(for: .turnLeft), style: StrokeStyle(lineWidth: 10, lineCap: .round))

            // 4. 右段 (向右微转: 315° ~ 45°)
            ArcSegment(startAngle: .degrees(315), endAngle: .degrees(405))
                .stroke(segmentColor(for: .turnRight), style: StrokeStyle(lineWidth: 10, lineCap: .round))
        }
    }

    private func segmentColor(for pose: TargetPose) -> Color {
        if completedPoses.contains(pose) {
            return Color.green
        } else if currentPose == pose {
            return isMatching ? Color.green.opacity(0.8) : Color.accentColor
        } else {
            return Color.clear
        }
    }
}

struct ArcSegment: Shape {
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}
