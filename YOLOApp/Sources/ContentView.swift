import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DetectorViewModel()
    @State private var showBenchmark = false
    @State private var showSpeechSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("personSpeechSpeed") private var speechRate = 1.25
    @AppStorage("personSpeechVoice") private var speechVoice = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: viewModel.camera.session)
                .ignoresSafeArea()
            DetectionOverlay(detections: viewModel.detections, tags: viewModel.tags, imageSize: viewModel.imageSize)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statsHUD
                Spacer()
                controlPanel
            }
            .padding(.horizontal, 12)

            if viewModel.isLoading {
                ProgressView("正在加载模型…\n首次在 NPU 上加载需要编译，可能需要数秒")
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .onAppear {
            updateSpeechSettings()
            viewModel.start()
        }
        .onDisappear {
            viewModel.announcesPeople = false
            viewModel.announcements.stop()
            viewModel.camera.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                viewModel.announcesPeople = false
                viewModel.announcements.stop()
            }
        }
        .onChange(of: speechRate) { _, _ in updateSpeechSettings() }
        .onChange(of: speechVoice) { _, _ in updateSpeechSettings() }
        .sheet(isPresented: $showSpeechSettings) {
            speechSettings
        }
        .sheet(isPresented: $showBenchmark) {
            BenchmarkView(viewModel: viewModel)
        }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.detectionMode == .aprilTag ? "AprilTag" : viewModel.selectedModel?.name ?? "无模型")
                    .font(.headline)
                Text(viewModel.detectionMode == .aprilTag ? "CPU" : viewModel.computeMode.title)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                Spacer()
                Text(String(format: "%.1f FPS", viewModel.stats.fps))
                    .font(.headline.monospacedDigit())
            }
            if viewModel.detectionMode.runsYOLO {
                HStack(spacing: 12) {
                    metric("推理", String(format: "%.1f ms", viewModel.stats.inferenceMs))
                    metric("后处理", String(format: "%.2f ms", viewModel.stats.postprocessMs))
                    metric("目标", "\(viewModel.stats.objectCount)")
                }
            }
            if viewModel.detectionMode.runsAprilTag {
                HStack(spacing: 12) {
                    metric("AprilTag", String(format: "%.1f ms", viewModel.stats.tagMs))
                    metric("Tag", "\(viewModel.stats.tagCount)")
                    metric("内参", viewModel.stats.intrinsicsFromCamera ? "相机标定" : "FOV 估算")
                }
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            } else if let status = viewModel.statusMessage {
                Text(status).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 8)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundColor(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private var controlPanel: some View {
        let busy = viewModel.isLoading || viewModel.isBenchmarking
        return VStack(spacing: 12) {
            Picker("检测模式", selection: $viewModel.detectionMode) {
                ForEach(DetectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(busy)

            if viewModel.detectionMode.runsYOLO {
                yoloControls.disabled(busy)
                personSpeechControls
            }
            if viewModel.detectionMode.runsAprilTag {
                aprilTagControls.disabled(busy)
            }

            HStack {
                Menu {
                    ForEach(ModelGroup.groups(of: viewModel.models)) { group in
                        Section(group.title) {
                            ForEach(group.models) { model in
                                Button {
                                    viewModel.selectedModel = model
                                } label: {
                                    if model == viewModel.selectedModel {
                                        Label(model.menuTitle, systemImage: "checkmark")
                                    } else {
                                        Text(model.menuTitle)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(viewModel.selectedModel?.name ?? "选择模型", systemImage: "cube.box")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showBenchmark = true
                } label: {
                    Label("跑分对比", systemImage: "speedometer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(busy)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 8)
    }

    private var personSpeechControls: some View {
        HStack {
            Toggle("人车语音提醒", isOn: $viewModel.announcesPeople)
            Button {
                showSpeechSettings = true
            } label: {
                Label("语音设置", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.bordered)
        }
        .font(.subheadline)
    }

    private var speechSettings: some View {
        NavigationStack {
            Form {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("语速")
                        Spacer()
                        Text(String(format: "%.2f×", speechRate))
                            .monospacedDigit()
                    }
                    Slider(value: $speechRate, in: 0.75...1.60, step: 0.05)
                        .accessibilityLabel("语速")
                        .accessibilityValue(String(format: "%.2f 倍", speechRate))
                }
                Picker("中文语音", selection: $speechVoice) {
                    Text("系统普通话").tag("")
                    ForEach(PersonAnnouncements.voices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                    }
                }
                Button {
                    updateSpeechSettings()
                    viewModel.announcements.preview()
                } label: {
                    Label("试听播报", systemImage: "play.circle")
                }
            }
            .navigationTitle("语音设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSpeechSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func updateSpeechSettings() {
        viewModel.announcements.speedMultiplier = speechRate
        viewModel.announcements.voiceIdentifier = speechVoice
    }

    @ViewBuilder
    private var yoloControls: some View {
        Picker("计算单元", selection: $viewModel.computeMode) {
            ForEach(ComputeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        Text(viewModel.computeMode.detail)
            .font(.caption2)
            .foregroundColor(.secondary)

        HStack {
            Text("置信度").font(.caption)
            Slider(value: $viewModel.confidence, in: 0.05...0.95, step: 0.05)
            Text(String(format: "%.2f", viewModel.confidence))
                .font(.caption.monospacedDigit())
                .frame(width: 36)
        }
    }

    @ViewBuilder
    private var aprilTagControls: some View {
        HStack {
            Stepper(value: $viewModel.tagSizeCM, in: 1...100, step: 0.1) {
                Text(String(format: "Tag 边长 %.1f cm", viewModel.tagSizeCM))
                    .font(.caption.monospacedDigit())
            }
            Picker("图案方向", selection: $viewModel.tagOrientation) {
                ForEach(TagPatternOrientation.allCases) { orientation in
                    Text(orientation.title).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }

        HStack {
            Text("平滑").font(.caption)
            Slider(value: $viewModel.tagSmoothing, in: 0...1)
            Text(viewModel.tagSmoothing < 0.34 ? "灵敏" : viewModel.tagSmoothing < 0.67 ? "均衡" : "稳定")
                .font(.caption)
                .frame(width: 36)
        }

        Text("tag36h11 · 原点=Tag 左上角 · X→右 Y→上 Z→垂直指出 Tag · 坐标为相机系 (cm)")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}
