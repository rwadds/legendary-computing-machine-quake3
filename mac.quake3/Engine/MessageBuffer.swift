// MessageBuffer.swift — Bit-level read/write message buffer (Q3 msg_t equivalent)

import Foundation

class MessageBuffer {
    var data: [UInt8]
    var maxSize: Int
    var curSize: Int = 0
    var readCount: Int = 0
    var bit: Int = 0         // current bit position for bit-level I/O
    var overflowed: Bool = false
    var allowOverflow: Bool = false
    var oob: Bool = false    // out-of-band mode (no Huffman, byte-aligned)

    init(capacity: Int) {
        self.data = [UInt8](repeating: 0, count: capacity)
        self.maxSize = capacity
    }

    init(data: [UInt8]) {
        self.data = data
        self.maxSize = data.count
        self.curSize = data.count
    }

    func clear() {
        curSize = 0
        readCount = 0
        bit = 0
        overflowed = false
    }

    // MARK: - Bit-level Write

    func writeBits(_ value: Int32, _ numBits: Int) {
        let bits = abs(numBits)
        guard bits > 0 && bits <= 32 else { return }

        if oob {
            // OOB mode: byte-aligned writes
            if bits == 8 {
                writeByte(Int32(value & 0xFF))
            } else if bits == 16 {
                writeShort(value)
            } else if bits == 32 {
                writeLong(value)
            }
            return
        }

        // Bit-stream mode
        var val = UInt32(bitPattern: value)
        var remaining = bits

        while remaining > 0 {
            let byteIndex = bit >> 3
            if byteIndex >= maxSize {
                overflowed = true
                return
            }

            let bitOffset = bit & 7
            let bitsToWrite = min(remaining, 8 - bitOffset)
            let mask = UInt8((1 << bitsToWrite) - 1)

            data[byteIndex] &= ~(mask << bitOffset)
            data[byteIndex] |= UInt8(val & UInt32(mask)) << bitOffset

            val >>= bitsToWrite
            bit += bitsToWrite
            remaining -= bitsToWrite
        }

        // Update curSize to reflect bit position
        curSize = (bit + 7) >> 3
    }

    // MARK: - Bit-level Read

    func readBits(_ numBits: Int) -> Int32 {
        let bits = abs(numBits)
        let signed = numBits < 0
        guard bits > 0 && bits <= 32 else { return 0 }

        if oob {
            // OOB mode
            if bits == 8 {
                return readByte()
            } else if bits == 16 {
                return readShort()
            } else if bits == 32 {
                return readLong()
            }
            return 0
        }

        var value: UInt32 = 0
        var remaining = bits
        var bitShift = 0

        while remaining > 0 {
            let byteIndex = bit >> 3
            if byteIndex >= curSize {
                overflowed = true
                return -1
            }

            let bitOffset = bit & 7
            let bitsToRead = min(remaining, 8 - bitOffset)
            let mask = UInt8((1 << bitsToRead) - 1)
            let bits8 = (data[byteIndex] >> bitOffset) & mask

            value |= UInt32(bits8) << bitShift

            bit += bitsToRead
            bitShift += bitsToRead
            remaining -= bitsToRead
        }

        readCount = (bit + 7) >> 3

        if signed && bits < 32 {
            // Sign extend
            if value & (1 << (bits - 1)) != 0 {
                value |= UInt32(bitPattern: Int32(-1)) << bits
            }
        }

        return Int32(bitPattern: value)
    }

    // MARK: - Byte-level Write

    func writeChar(_ c: Int32) {
        checkOverflow(1)
        data[curSize] = UInt8(bitPattern: Int8(truncatingIfNeeded: c))
        curSize += 1
        bit = curSize << 3
    }

    func writeByte(_ c: Int32) {
        checkOverflow(1)
        data[curSize] = UInt8(c & 0xFF)
        curSize += 1
        bit = curSize << 3
    }

    func writeShort(_ c: Int32) {
        checkOverflow(2)
        data[curSize] = UInt8(c & 0xFF)
        data[curSize + 1] = UInt8((c >> 8) & 0xFF)
        curSize += 2
        bit = curSize << 3
    }

    func writeLong(_ c: Int32) {
        checkOverflow(4)
        data[curSize] = UInt8(c & 0xFF)
        data[curSize + 1] = UInt8((c >> 8) & 0xFF)
        data[curSize + 2] = UInt8((c >> 16) & 0xFF)
        data[curSize + 3] = UInt8((c >> 24) & 0xFF)
        curSize += 4
        bit = curSize << 3
    }

    func writeFloat(_ f: Float) {
        let i = f.bitPattern
        writeLong(Int32(bitPattern: i))
    }

    func writeString(_ s: String) {
        let bytes = Array(s.utf8)
        for b in bytes {
            writeByte(Int32(b))
        }
        writeByte(0) // null terminator
    }

    func writeData(_ bytes: [UInt8]) {
        for b in bytes {
            writeByte(Int32(b))
        }
    }

    func writeAngle16(_ f: Float) {
        writeShort(Int32(ANGLE2SHORT(f)))
    }

    // MARK: - Byte-level Read

    func beginReading() {
        readCount = 0
        bit = 0
        oob = false
    }

    func beginReadingOOB() {
        readCount = 0
        bit = 0
        oob = true
    }

    func readChar() -> Int32 {
        guard readCount < curSize else {
            overflowed = true
            return -1
        }
        let c = Int8(bitPattern: data[readCount])
        readCount += 1
        bit = readCount << 3
        return Int32(c)
    }

    func readByte() -> Int32 {
        guard readCount < curSize else {
            overflowed = true
            return -1
        }
        let c = data[readCount]
        readCount += 1
        bit = readCount << 3
        return Int32(c)
    }

    func readShort() -> Int32 {
        guard readCount + 1 < curSize else {
            overflowed = true
            return -1
        }
        let c = Int16(data[readCount]) | (Int16(data[readCount + 1]) << 8)
        readCount += 2
        bit = readCount << 3
        return Int32(c)
    }

    func readLong() -> Int32 {
        guard readCount + 3 < curSize else {
            overflowed = true
            return -1
        }
        let c = Int32(data[readCount])
            | (Int32(data[readCount + 1]) << 8)
            | (Int32(data[readCount + 2]) << 16)
            | (Int32(data[readCount + 3]) << 24)
        readCount += 4
        bit = readCount << 3
        return c
    }

    func readFloat() -> Float {
        let bits = UInt32(bitPattern: readLong())
        return Float(bitPattern: bits)
    }

    func readString() -> String {
        var chars: [UInt8] = []
        while true {
            let c = readByte()
            if c <= 0 { break }
            if chars.count < MAX_STRING_CHARS - 1 {
                chars.append(UInt8(c))
            }
        }
        return String(bytes: chars, encoding: .utf8) ?? ""
    }

    func readStringLine() -> String {
        var chars: [UInt8] = []
        while true {
            let c = readByte()
            if c <= 0 || c == Int32(Character("\n").asciiValue!) { break }
            if chars.count < MAX_STRING_CHARS - 1 {
                chars.append(UInt8(c))
            }
        }
        return String(bytes: chars, encoding: .utf8) ?? ""
    }

    func readAngle16() -> Float {
        return SHORT2ANGLE(Int(readShort()))
    }

    func readData(_ count: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let b = readByte()
            if overflowed { break }
            result[i] = UInt8(b & 0xFF)
        }
        return result
    }

    // MARK: - Delta Compression Helpers

    func writeDeltaKey(_ key: Int32, _ oldValue: Int32, _ newValue: Int32, _ bits: Int) {
        if oldValue == newValue {
            writeBits(0, 1) // no change
        } else {
            writeBits(1, 1) // changed
            writeBits(newValue ^ key, bits)
        }
    }

    func readDeltaKey(_ key: Int32, _ oldValue: Int32, _ bits: Int) -> Int32 {
        if readBits(1) != 0 {
            return readBits(bits) ^ key
        }
        return oldValue
    }

    // MARK: - Utility

    var bytesRemaining: Int {
        return curSize - readCount
    }

    var isAtEnd: Bool {
        return readCount >= curSize
    }

    private func checkOverflow(_ needed: Int) {
        if curSize + needed > maxSize {
            if !allowOverflow {
                Q3Console.shared.print("MessageBuffer: overflow (size=\(curSize), max=\(maxSize), need=\(needed))")
            }
            overflowed = true
        }
    }

    func copy() -> MessageBuffer {
        let msg = MessageBuffer(capacity: maxSize)
        msg.data = Array(data[0..<curSize])
        msg.curSize = curSize
        msg.readCount = readCount
        msg.bit = bit
        msg.oob = oob
        return msg
    }
}

// MARK: - Network Message Types

enum ServerMessage: UInt8 {
    case bad = 0
    case nop
    case gamestate
    case configstring   // [short] [string] in gamestate only
    case baseline       // in gamestate only
    case serverCommand  // [string] to execute
    case download       // [short] size [size bytes]
    case snapshot
    case eof
}

enum ClientMessage: UInt8 {
    case bad = 0
    case nop
    case move           // [usercmd_t]
    case moveNoDelta    // [usercmd_t]
    case clientCommand  // [string]
    case eof
}
