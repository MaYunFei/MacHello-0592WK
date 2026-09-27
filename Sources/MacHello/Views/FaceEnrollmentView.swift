import SwiftUI
import AppKit
import MacHelloCore

final class EnrollmentViewModel: ObservableObject, FaceEnrollmentDelegate {
    @Published var previewImage: CGImage?
    @Published var stage: EnrollmentStage = .regular
    @Published var targetPose: TargetPose = .center
    @Published var completedPoses: Set<TargetPose> = []
    @Published var progress: Double = 0.0
    @Published var instruction: String = "请正视摄像头，保持平视"
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
            // 清洗 emoji，保持苹果原生的高级感排版
            let cleanMsg = message
                .replacingOccurrences(of: "👀 ", with: "")
                .replacingOccurrences(of: "👈 ", with: "")
                .replacingOccurrences(of: "👉 ", with: "")
                .replacingOccurrences(of: "👆 ", with: "")
            self.instruction = cleanMsg
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
            // 背景深色极简材质
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            if viewModel.isFinished {
                successView
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if viewModel.showAlternativePrompt {
                alternativePromptView
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                enrollmentMainView
                    .transition(.opacity)
            }
        }
        .frame(width: 500, height: 600)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.isFinished)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.showAlternativePrompt)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    // MARK: - 主录入界面 (Apple Face ID 风格)
    private var enrollmentMainView: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text(viewModel.stage == .regular ? "步骤 1/2 • 日常外观" : "步骤 2/2 • 替用外观")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(Capsule())

                Spacer()

                Button(action: {
                    viewModel.cancel()
                    onDismiss?()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()

            // 核心扫描环与圆形视频取景框
            ZStack {
                // 1. 动态四段圆环 (上、下、左、右)
                FaceIDProgressRing(
                    completedPoses: viewModel.completedPoses,
                    currentPose: viewModel.targetPose,
                    isMatching: viewModel.isMatchingCurrentPose
                )
                .frame(width: 260, height: 260)

                // 2. 内部红外实时视频镜面预览
                if let cgImage = viewModel.previewImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(x: -1, y: 1) // 水平镜像翻转
                        .frame(width: 228, height: 228)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                        )
                } else {
                    Circle()
                        .fill(Color.black.opacity(0.85))
                        .frame(width: 228, height: 228)
                        .overlay(
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在开启红外夜视镜头...")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        )
                }

                // 3. 匹配时的高光呼吸发光环
                Circle()
                    .stroke(Color.green.opacity(0.85), lineWidth: 3.5)
                    .frame(width: 232, height: 232)
                    .blur(radius: 2)
                    .opacity(viewModel.isMatchingCurrentPose ? 1.0 : 0.0)
                    .scaleEffect(viewModel.isMatchingCurrentPose ? 1.02 : 0.98)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: viewModel.isMatchingCurrentPose)

                // 4. 定格成功微标浮层 (Spring 弹性弹现)
                if viewModel.isPoseFrozen {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.green)
                            .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)

                        Text("角度已捕获")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }

            Spacer()

            // 底部指示文案区
            VStack(spacing: 8) {
                Text(viewModel.instruction)
                    .font(.title3)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .foregroundColor(viewModel.isMatchingCurrentPose ? .green : .primary)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isMatchingCurrentPose)

                ZStack {
                    Text(viewModel.isPoseFrozen ? "角度捕获成功，定格中..." : "保持当前姿态，正在录入特征...")
                        .font(.subheadline)
                        .foregroundColor(.green)
                        .opacity((viewModel.isMatchingCurrentPose || viewModel.isPoseFrozen) ? 1.0 : 0.0)

                    Text("缓慢转动面部，对齐指示角度")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .opacity((!viewModel.isMatchingCurrentPose && !viewModel.isPoseFrozen) ? 1.0 : 0.0)
                }
                .animation(.easeInOut(duration: 0.2), value: viewModel.isMatchingCurrentPose)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isPoseFrozen)
            }
            .frame(height: 56)

            // 进度指示器
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 5)

                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(viewModel.progress))), height: 5)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.progress)
                    }
                }
                .frame(height: 5)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 32)
        }
    }

    // MARK: - 替用外观询问界面
    private var alternativePromptView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 90, height: 90)

                Image(systemName: "eyeglasses")
                    .font(.system(size: 44))
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 8) {
                Text("第一阶段录入完成")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text("建议设置脱镜 / 替用外观")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Text("如果您平时戴眼镜，请摘下眼镜再录入一次。\n这样无论您是否佩戴眼镜，Mac 都能快速识别并秒级解锁。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 12) {
                Button(action: {
                    viewModel.startAlternative()
                }) {
                    Text("摘下眼镜并开始录入")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    viewModel.skipAlternative()
                }) {
                    Text("跳过此步 (平时不戴眼镜)")
                        .font(.subheadline)
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
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 96, height: 96)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 58))
                    .foregroundColor(.green)
            }

            VStack(spacing: 8) {
                Text("面容 ID 已设置完成")
                    .font(.title)
                    .fontWeight(.bold)

                Text("已提取并存储 \(viewModel.totalSamplesCount) 组红外 3D 特征向量")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("现在您可以使用 Dell CN-0592WK 摄像头\n进行人脸感应亮屏与近红外活体全场景解锁。")
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
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 48)
            .padding(.bottom, 36)
        }
    }
}

// MARK: - Apple Face ID 风格动态四段圆环
struct FaceIDProgressRing: View {
    let completedPoses: Set<TargetPose>
    let currentPose: TargetPose
    let isMatching: Bool

    var body: some View {
        ZStack {
            // 背景底环
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 10)

            // 1. 上段 (微微抬头: 225° ~ 315°)
            ArcSegment(startAngle: .degrees(225), endAngle: .degrees(315))
                .stroke(segmentColor(for: .tiltUp), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .scaleEffect(segmentScale(for: .tiltUp))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: completedPoses.contains(.tiltUp))

            // 2. 下段 (正视镜头: 45° ~ 135°)
            ArcSegment(startAngle: .degrees(45), endAngle: .degrees(135))
                .stroke(segmentColor(for: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .scaleEffect(segmentScale(for: .center))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: completedPoses.contains(.center))

            // 3. 左段 (向左微转: 135° ~ 225°)
            ArcSegment(startAngle: .degrees(135), endAngle: .degrees(225))
                .stroke(segmentColor(for: .turnLeft), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .scaleEffect(segmentScale(for: .turnLeft))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: completedPoses.contains(.turnLeft))

            // 4. 右段 (向右微转: 315° ~ 405°)
            ArcSegment(startAngle: .degrees(315), endAngle: .degrees(405))
                .stroke(segmentColor(for: .turnRight), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .scaleEffect(segmentScale(for: .turnRight))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: completedPoses.contains(.turnRight))
        }
    }

    private func segmentColor(for pose: TargetPose) -> Color {
        if completedPoses.contains(pose) {
            return Color.green
        } else if currentPose == pose {
            return isMatching ? Color.green.opacity(0.85) : Color.accentColor
        } else {
            return Color.clear
        }
    }

    private func segmentScale(for pose: TargetPose) -> CGFloat {
        if completedPoses.contains(pose) {
            return 1.02
        } else if currentPose == pose && isMatching {
            return 1.03
        } else {
            return 1.0
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
