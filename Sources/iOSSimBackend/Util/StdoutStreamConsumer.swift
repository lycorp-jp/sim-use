// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import FBControlCore
import SimUseVideo

/// Bridges idb's byte-stream consumer protocol to `StdoutStreamSink`, so a
/// native `FBVideoStream` copied to stdout stays interruptible.
///
/// idb's own `FBFileWriter.syncWriter` blocks in `write(2)` on the encoder's
/// callback thread. When the consumer stops reading (ffplay paused, a
/// downstream tool wedged) that write never returns, `stopStreaming()` waits
/// behind it, and the command cannot be stopped short of SIGKILL. The sink
/// writes only when the kernel has room and consults the cancellation flag
/// while it waits, so Ctrl-C always gets the thread back.
final class StdoutStreamConsumer: NSObject, FBDataConsumer {
    private let sink: StdoutStreamSink
    private let onHangup: @Sendable () -> Void

    /// - Parameter onHangup: called once when the consumer closes its end
    ///   of the pipe — an orderly end-of-stream, not an error.
    init(sink: StdoutStreamSink, onHangup: @escaping @Sendable () -> Void) {
        self.sink = sink
        self.onHangup = onHangup
        super.init()
    }

    func consumeData(_ data: Data) {
        if !sink.write(data), sink.isBroken {
            onHangup()
        }
    }

    func consumeEndOfFile() {}
}
