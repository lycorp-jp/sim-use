// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBControlCore

public final class SimUseLogger: FBCompositeLogger {
    public override init(loggers: [FBControlCoreLogger]) {
        super.init(loggers: loggers)
    }
    
    public convenience init(debugLogging: Bool = false, writeToStdErr: Bool = true) {
        let systemLogger = FBControlCoreLoggerFactory.systemLoggerWriting(
            toStderr: writeToStdErr,
            withDebugLogging: debugLogging
        )
        self.init(loggers: [systemLogger])
    }
    
    public override convenience init() {
        self.init(debugLogging: false, writeToStdErr: false)
    }
    
    public func makeDefault() {
        FBControlCoreGlobalConfiguration.defaultLogger = self
    }
    
    public func warning() -> FBControlCoreLogger {
        return self.debug()
    }
}