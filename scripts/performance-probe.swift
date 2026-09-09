import Foundation
import Darwin

// Developer-only, bounded external sampler. Never reads app memory, credentials or URLs.
let args = CommandLine.arguments
let duration = min(600, max(1, Double(args.dropFirst().first ?? "240") ?? 240))
let interval = min(60, max(1, Double(args.dropFirst(2).first ?? "10") ?? 10))
let executable = "/Applications/NotchQuota.app/Contents/MacOS/NotchQuota"
let version = Bundle(path: "/Applications/NotchQuota.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
}
func findPID() -> pid_t? {
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    for pid in pids.prefix(max(0, Int(count))) where pid > 0 {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == executable { return pid }
    }
    return nil
}
func usage(_ pid: pid_t) -> rusage_info_v2? {
    var value = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &value) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    return result == 0 ? value : nil
}
guard let pid = findPID(), var previous = usage(pid) else { emit(["event": "not_running", "timestamp": Date().timeIntervalSince1970, "version": version]); exit(0) }
let started = ProcessInfo.processInfo.systemUptime
var lastTime = started
emit(["event": "start", "timestamp": Date().timeIntervalSince1970, "pid": pid, "version": version, "interval_s": interval, "duration_s": duration])
while ProcessInfo.processInfo.systemUptime - started < duration {
    Thread.sleep(forTimeInterval: min(interval, max(0.01, duration - (ProcessInfo.processInfo.systemUptime - started))))
    guard let current = usage(pid), current.ri_proc_start_abstime == previous.ri_proc_start_abstime else {
        emit(["event": "process_ended", "timestamp": Date().timeIntervalSince1970, "pid": pid]); break
    }
    let now = ProcessInfo.processInfo.systemUptime, elapsed = now - lastTime
    let cpu = Double((current.ri_user_time - previous.ri_user_time) + (current.ri_system_time - previous.ri_system_time)) / 1e9 / elapsed * 100
    emit(["event": "sample", "timestamp": Date().timeIntervalSince1970, "pid": pid, "version": version,
          "interval_s": elapsed, "cpu_percent_one_core": cpu, "rss_mib": Double(current.ri_resident_size) / 1048576,
          "footprint_mib": Double(current.ri_phys_footprint) / 1048576,
          "idle_wakeups_per_s": Double(current.ri_pkg_idle_wkups - previous.ri_pkg_idle_wkups) / elapsed,
          "disk_read_bytes": current.ri_diskio_bytesread - previous.ri_diskio_bytesread,
          "disk_write_bytes": current.ri_diskio_byteswritten - previous.ri_diskio_byteswritten])
    previous = current; lastTime = now
}
