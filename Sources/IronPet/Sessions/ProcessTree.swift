import Darwin
import Foundation

/// Finds the app that started an agent by walking its parent processes.
enum ProcessTree {
    /// Bundle id of the first ancestor (the process itself included) whose executable lives inside a `.app`.
    /// The lookups are injectable so tests don't need real processes.
    static func owningBundleID(
        pid: Int32,
        parent: (Int32) -> Int32? = realParent,
        executablePath: (Int32) -> String? = realPath,
        bundleID: (String) -> String? = realBundleID
    ) -> String? {
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted {
            if let path = executablePath(current), let app = appBundlePath(in: path), let id = bundleID(app) { return id }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    /// `/Applications/Band.app` for `/Applications/Band.app/Contents/MacOS/Band`. The outermost `.app` wins, so a
    /// helper bundle nested inside an app reports the app.
    static func appBundlePath(in executable: String) -> String? {
        guard let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    static func realParent(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    static func realPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func realBundleID(_ appPath: String) -> String? {
        Bundle(path: appPath)?.bundleIdentifier
    }
}
