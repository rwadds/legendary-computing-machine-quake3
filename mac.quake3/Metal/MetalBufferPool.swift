// MetalBufferPool.swift — Ring-buffered dynamic allocation (3-frame)

import Foundation
import Metal

class MetalBufferPool {
    let device: MTLDevice
    private let maxFramesInFlight = 3
    private var buffers: [MTLBuffer] = []
    private var offsets: [Int] = []
    private var currentFrame = 0
    private let alignment = 256

    init(device: MTLDevice, size: Int) {
        self.device = device
        for i in 0..<maxFramesInFlight {
            guard let buf = device.makeBuffer(length: size, options: .storageModeShared) else {
                fatalError("Failed to create buffer pool buffer \(i)")
            }
            buf.label = "DynamicBuffer_\(i)"
            buffers.append(buf)
            offsets.append(0)
        }
    }

    func nextFrame() {
        currentFrame = (currentFrame + 1) % maxFramesInFlight
        offsets[currentFrame] = 0
    }

    func allocate(size: Int) -> (buffer: MTLBuffer, offset: Int)? {
        let alignedSize = (size + alignment - 1) & ~(alignment - 1)
        let buf = buffers[currentFrame]
        let offset = offsets[currentFrame]

        guard offset + alignedSize <= buf.length else { return nil }
        offsets[currentFrame] = offset + alignedSize
        return (buf, offset)
    }

    func currentBuffer() -> MTLBuffer {
        return buffers[currentFrame]
    }

    func currentOffset() -> Int {
        return offsets[currentFrame]
    }
}
