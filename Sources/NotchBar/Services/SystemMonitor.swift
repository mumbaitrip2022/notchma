import Darwin
import Foundation

/// Live CPU, memory and disk — from the same sources Activity Monitor and Finder use.
///
/// Cost model: samples every 1.5s only while the notch is expanded (`setLive(true)`).
/// Collapsed, memory pressure arrives as a kernel event (no polling) and disk is
/// checked once a minute, just to warn before it runs out.
final class SystemMonitor: ObservableObject {
    enum Pressure: Int { case normal = 1, warning = 2, critical = 4 }

    // CPU (0–100, whole machine). `agentCPU` is the part used by agent processes and everything they spawn.
    @Published private(set) var cpu: Double = 0
    @Published private(set) var agentCPU: Double = 0
    @Published private(set) var cpuReady = false
    // Memory — "Memory Used" as Activity Monitor defines it: app + wired + compressed.
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var memCompressed: UInt64 = 0
    let memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var pressure: Pressure = .normal
    // Disk — "available" as Finder reports it (includes space macOS can purge).
    @Published private(set) var diskFree: Int64 = 0      // incl. purgeable (what Finder shows)
    @Published private(set) var diskFreeNow: Int64 = 0   // free this instant (what `df` shows)
    @Published private(set) var diskTotal: Int64 = 0

    /// PIDs of the agent processes to attribute CPU to (sessions' claude/codex processes).
    var agentRoots: () -> [pid_t] = { [] }
    var onDiskLow: ((_ freeBytes: Int64, _ critical: Bool) -> Void)?
    var onMemoryCritical: (() -> Void)?

    private let queue = DispatchQueue(label: "notchbar.system", qos: .utility)
    private var liveTimer: DispatchSourceTimer?
    private var diskTimer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastProcTimes: [pid_t: UInt64] = [:]
    // Agent process tree, rebuilt every few samples (listing every process is the costly part).
    private var cachedTree: [pid_t] = []
    private var cachedRoots: [pid_t] = []
    private var samplesSinceTree = 0
    private var liveTicks = 0
    private var lastSampleAt: UInt64 = 0
    private var diskWarned: Int = 0 // 0 none, 1 low, 2 critical
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
    }()

    init() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.refreshPressure(fromEvent: true) }
        src.resume()
        pressureSource = src

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 60, leeway: .seconds(15))
        t.setEventHandler { [weak self] in self?.sampleDisk() }
        t.resume()
        diskTimer = t
        refreshPressure(fromEvent: false)
    }

    /// Sample every 1.5s while visible; stop entirely when hidden.
    func setLive(_ live: Bool) {
        if live {
            guard liveTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.5, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.sampleLive() }
            t.resume()
            liveTimer = t
        } else {
            liveTimer?.cancel()
            liveTimer = nil
            lastTicks = nil          // first sample after reopening re-baselines
            lastProcTimes = [:]
            DispatchQueue.main.async { self.cpuReady = false }
        }
    }

    // MARK: sampling (on `queue`)

    private func sampleLive() {
        let roots = DispatchQueue.main.sync { self.agentRoots() }
        let total = cpuLoad()
        let agents = agentLoad(roots: roots)
        let mem = memory()
        // Disk changes slowly and its "available" figure is costly to compute: every ~15s.
        liveTicks += 1
        if liveTicks % 10 == 1 { sampleDisk(publishOnly: true) }
        DispatchQueue.main.async {
            if let total {
                self.cpu = total
                self.agentCPU = min(agents ?? 0, total)
                self.cpuReady = true
            }
            if let mem { self.memUsed = mem.used; self.memCompressed = mem.compressed }
        }
        refreshPressure(fromEvent: false)
    }

    /// Whole-machine CPU busy % from kernel tick counters (delta between samples).
    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + system + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total) * 100
    }

    /// CPU used by agent processes *and everything they spawned* (builds, tests, servers),
    /// as a share of the whole machine — directly comparable with `cpu`.
    private func agentLoad(roots: [pid_t]) -> Double? {
        let now = mach_absolute_time()
        defer { lastSampleAt = now }
        guard !roots.isEmpty else { lastProcTimes = [:]; cachedTree = []; return 0 }
        // Rebuild the tree every 4th sample (~6s) or when the agents change; in between,
        // only the known processes are read — new children show up within seconds.
        samplesSinceTree += 1
        if roots.sorted() != cachedRoots || samplesSinceTree >= 4 || cachedTree.isEmpty {
            guard let procs = allProcesses() else { return nil }
            var children: [pid_t: [pid_t]] = [:]
            for (pid, ppid) in procs { children[ppid, default: []].append(pid) }
            var tree = Set<pid_t>(), stack = roots.filter { procs[$0] != nil }
            while let p = stack.popLast() {
                guard tree.insert(p).inserted else { continue }
                stack.append(contentsOf: children[p] ?? [])
            }
            cachedTree = Array(tree)
            cachedRoots = roots.sorted()
            samplesSinceTree = 0
        }
        let tree = cachedTree
        var times: [pid_t: UInt64] = [:]
        var used: UInt64 = 0
        for pid in tree {
            var ti = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { continue }
            let t = ti.pti_total_user + ti.pti_total_system // Mach time units
            times[pid] = t
            if let prev = lastProcTimes[pid], t >= prev { used += t - prev }
        }
        lastProcTimes = times
        guard lastSampleAt > 0, now > lastSampleAt else { return nil }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let elapsed = Double(now - lastSampleAt) // both in Mach units, so the timebase cancels
        return Double(used) / (elapsed * cores) * 100
    }

    /// pid → parent pid for every process, in one sysctl.
    private func allProcesses() -> [pid_t: pid_t]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        size += size / 8 // room for processes started in between
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        var map: [pid_t: pid_t] = [:]
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) where p.kp_proc.p_pid > 0 {
            map[p.kp_proc.p_pid] = p.kp_eproc.e_ppid
        }
        return map
    }

    /// Activity Monitor's "Memory Used": app memory (anonymous − purgeable) + wired + compressed.
    private func memory() -> (used: UInt64, compressed: UInt64)? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        return (min(used, memTotal), UInt64(vm.compressor_page_count) * page)
    }

    private func refreshPressure(fromEvent: Bool) {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let p = Pressure(rawValue: Int(level)) ?? .normal
        DispatchQueue.main.async {
            let wasCritical = self.pressure == .critical
            self.pressure = p
            if p == .critical && !wasCritical { self.onMemoryCritical?() }
        }
    }

    /// Free space on your data volume, as Finder shows it.
    private func sampleDisk(publishOnly: Bool = false) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return }
        let now = Int64(v.volumeAvailableCapacity ?? Int(free))
        DispatchQueue.main.async {
            self.diskFree = free
            self.diskFreeNow = now
            self.diskTotal = Int64(total)
            guard !publishOnly else { return }
            // Warn once when crossing 10 GB / 3 GB; re-arm after recovering above 15 GB.
            let gb: Int64 = 1_000_000_000
            let level = free < 3 * gb ? 2 : (free < 10 * gb ? 1 : 0)
            if level > self.diskWarned { self.onDiskLow?(free, level == 2) }
            if level > self.diskWarned || free > 15 * gb { self.diskWarned = level }
        }
    }

    // MARK: formatting

    /// Memory uses binary units (like Activity Monitor), disk uses decimal (like Finder).
    static func memString(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
    static func diskString(_ b: Int64) -> String {
        let gb = Double(b) / 1_000_000_000
        return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }
}
