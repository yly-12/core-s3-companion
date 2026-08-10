import Darwin
import Foundation

struct CPUTicks: Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var active: UInt64 { user + system + nice }
    var total: UInt64 { active + idle }
}

struct CPUUsageCalculator {
    private(set) var previousTicks: CPUTicks?

    mutating func consume(_ ticks: CPUTicks) -> UInt8? {
        defer { previousTicks = ticks }
        guard let previousTicks else { return nil }

        guard ticks.user >= previousTicks.user,
              ticks.system >= previousTicks.system,
              ticks.idle >= previousTicks.idle,
              ticks.nice >= previousTicks.nice else {
            return nil
        }

        let activeDelta = ticks.active - previousTicks.active
        let totalDelta = ticks.total - previousTicks.total
        guard totalDelta > 0 else { return nil }

        let percentage = (Double(activeDelta) / Double(totalDelta) * 100).rounded()
        return UInt8(max(0, min(100, percentage)))
    }
}

protocol CPUUsageSampling: AnyObject {
    var onSample: ((UInt8) -> Void)? { get set }
    func start()
    func stop()
}

final class CPUUsageSampler: CPUUsageSampling {
    var onSample: ((UInt8) -> Void)?

    private var calculator = CPUUsageCalculator()
    private var timer: Timer?
    private let readTicks: () -> CPUTicks?

    init(readTicks: (() -> CPUTicks?)? = nil) {
        self.readTicks = readTicks ?? SystemCPUTickReader.read
    }

    func start() {
        guard timer == nil else { return }
        sample()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let ticks = readTicks(), let usage = calculator.consume(ticks) else {
            return
        }
        onSample?(usage)
    }

    deinit {
        timer?.invalidate()
    }
}

private enum SystemCPUTickReader {
    static func read() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride /
                MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { reboundPointer in
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(
            user: UInt64(ticks.0),
            system: UInt64(ticks.1),
            idle: UInt64(ticks.2),
            nice: UInt64(ticks.3)
        )
    }
}

