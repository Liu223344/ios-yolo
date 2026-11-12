import AVFoundation
import QuartzCore

final class PersonAnnouncements {
    private enum Direction: String {
        case left = "左前"
        case center = "正前"
        case right = "右前"

        var conversational: String {
            switch self {
            case .left: return "左前边"
            case .center: return "前面"
            case .right: return "右前边"
            }
        }

        init(x: CGFloat) {
            if x < 0.38 { self = .left }
            else if x > 0.62 { self = .right }
            else { self = .center }
        }
    }

    private enum Kind: Hashable {
        case person, car, twoWheeler

        init?(label: String) {
            switch label.lowercased() {
            case "person": self = .person
            case "car": self = .car
            case "motorcycle": self = .twoWheeler
            default: return nil
            }
        }
    }

    private struct Topic: Hashable {
        let direction: Direction
        let kind: Kind
    }

    private struct Target {
        let topic: Topic
        let meters: Double?

        init?(_ detection: Detection) {
            guard detection.confidence >= 0.45, let kind = Kind(label: detection.label) else { return nil }
            topic = Topic(direction: Direction(x: detection.rect.midX), kind: kind)
            if case .meters(let value) = detection.distanceReading {
                meters = value
            } else {
                meters = nil
            }
        }
    }

    private enum CrowdSize: String {
        case one = "一人"
        case two = "两人"
        case group = "一群人"

        init(count: Int) {
            switch count {
            case 1: self = .one
            case 2: self = .two
            default: self = .group
            }
        }
    }

    private struct Observation {
        let size: CrowdSize
        let nearestMeters: Double?
    }

    private struct TopicState {
        var current: Observation
        var stableSince: CFTimeInterval
        var lastSeen: CFTimeInterval
        var spoken: Observation?
    }

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh-") }
            .sorted { ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier) }
    }

    var speedMultiplier = 1.25
    var voiceIdentifier = ""
    private let synthesizer = AVSpeechSynthesizer()
    private var topics: [Topic: TopicState] = [:]
    private var lastSpoken: CFTimeInterval = -.infinity
    private var phraseIndex = 0

    init() {
        synthesizer.usesApplicationAudioSession = false
    }

    func observe(_ detections: [Detection], at now: CFTimeInterval = CACurrentMediaTime()) {
        let targets = detections.sorted { $0.confidence > $1.confidence }.compactMap(Target.init)
        let groups = Dictionary(grouping: targets, by: \.topic)
        topics = topics.filter { now - $0.value.lastSeen <= 0.8 }

        for (topic, group) in groups {
            let observation = Observation(size: CrowdSize(count: group.count),
                                          nearestMeters: group.compactMap(\.meters).min())
            var state = topics[topic] ?? TopicState(current: observation, stableSince: now, lastSeen: now)
            if state.current.size != observation.size { state.stableSince = now }
            state.current = observation
            state.lastSeen = now
            topics[topic] = state
        }

        guard now - lastSpoken >= 2, !synthesizer.isSpeaking else { return }
        let ordered = targets.sorted { ($0.meters ?? .infinity) < ($1.meters ?? .infinity) }
        for target in ordered {
            guard var state = topics[target.topic], now - state.stableSince >= 0.25 else { continue }
            if let spoken = state.spoken, spoken.size == state.current.size {
                guard let current = state.current.nearestMeters else { continue }
                if let previous = spoken.nearestMeters, previous - current < 0.75 { continue }
            }
            speak(message(for: target.topic, observation: state.current))
            phraseIndex += 1
            state.spoken = state.current
            topics[target.topic] = state
            lastSpoken = now
            return
        }
    }

    func preview() {
        synthesizer.stopSpeaking(at: .immediate)
        speak("左前有车，两米。")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        topics.removeAll()
        lastSpoken = -.infinity
    }

    private func message(for topic: Topic, observation: Observation) -> String {
        let direction = phraseIndex.isMultiple(of: 2) ? topic.direction.rawValue : topic.direction.conversational
        let subject: String
        switch topic.kind {
        case .person: subject = observation.size == .group ? "有一群人" : observation.size.rawValue
        case .car: subject = "有车"
        case .twoWheeler: subject = "有两轮车"
        }
        let prefix = direction + subject
        guard let meters = observation.nearestMeters else { return prefix }
        return prefix + "，" + (observation.size == .one ? "" : "最近") + Self.spokenDistance(meters)
    }

    private static func spokenDistance(_ meters: Double) -> String {
        if meters < 0.75 { return "不到一米" }
        let halfMeters = (meters * 2).rounded()
        guard halfMeters < 20 else { return String(format: "约%.0f米", meters) }
        let whole = Int(halfMeters) / 2
        let names = ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九"]
        let suffix = Int(halfMeters).isMultiple(of: 2) ? "米" : "米半"
        return names[whole] + suffix
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let requestedRate = AVSpeechUtteranceDefaultSpeechRate * Float(speedMultiplier)
        utterance.rate = min(max(requestedRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        synthesizer.speak(utterance)
    }
}
