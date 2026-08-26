import Darwin
import Foundation

enum AppInstanceLock {
    private static var lockFileDescriptor: Int32 = -1

    static func acquire() -> Bool {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/StayAwake", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            print("StayAwake: Failed to create cache directory: \(error)")
            return false
        }

        let lockPath = cacheDir.appendingPathComponent("stayawake.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            print("StayAwake: Failed to open lock file")
            return false
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        lockFileDescriptor = fd
        return true
    }

    static func release() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }
}
