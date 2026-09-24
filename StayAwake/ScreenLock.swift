import Darwin

enum ScreenLock {
    /// Locks the session the same way Control-Command-Q does.
    @discardableResult
    static func lock() -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            RTLD_LAZY
        ) else {
            return false
        }
        defer { dlclose(handle) }

        typealias LockFunc = @convention(c) () -> Void
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            return false
        }

        let lockScreen = unsafeBitCast(symbol, to: LockFunc.self)
        lockScreen()
        return true
    }
}
