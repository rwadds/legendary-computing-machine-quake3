// QVM.swift — QVM file loader: parse vmHeader_t, code/data segments

import Foundation

class QVM {
    let name: String

    // Code
    var codeBase: [UInt8] = []       // Raw bytecode
    var codeLength: Int = 0
    var instructionCount: Int = 0
    var instructionPointers: [Int] = []  // Maps instruction index → byte offset in codeBase

    // Data memory (VM heap + stack)
    var dataBase: [UInt8] = []
    var dataLength: Int = 0
    var dataMask: Int = 0

    // Abort flag (set by trap_Error to stop VM execution)
    var aborted = false

    // Stack
    var programStack: Int32 = 0
    var stackBottom: Int32 = 0

    // Syscall handler
    var systemCall: ((_ args: UnsafePointer<Int32>, _ numArgs: Int, _ vm: QVM) -> Int32)?

    init(name: String) {
        self.name = name
    }

    // MARK: - Loading

    func load(from data: Data) -> Bool {
        guard data.count >= MemoryLayout<QVMHeader>.size else {
            Q3Console.shared.print("QVM \(name): file too small")
            return false
        }

        // Parse header
        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard magic == QVM_MAGIC else {
            Q3Console.shared.print("QVM \(name): bad magic 0x\(String(magic, radix: 16))")
            return false
        }

        let header = data.withUnsafeBytes { ptr -> QVMHeader in
            let p = ptr.baseAddress!
            return QVMHeader(
                vmMagic: p.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                instructionCount: p.loadUnaligned(fromByteOffset: 4, as: Int32.self),
                codeOffset: p.loadUnaligned(fromByteOffset: 8, as: Int32.self),
                codeLength: p.loadUnaligned(fromByteOffset: 12, as: Int32.self),
                dataOffset: p.loadUnaligned(fromByteOffset: 16, as: Int32.self),
                dataLength: p.loadUnaligned(fromByteOffset: 20, as: Int32.self),
                litLength: p.loadUnaligned(fromByteOffset: 24, as: Int32.self),
                bssLength: p.loadUnaligned(fromByteOffset: 28, as: Int32.self)
            )
        }

        Q3Console.shared.print("QVM \(name): instructions=\(header.instructionCount) code=\(header.codeLength) data=\(header.dataLength) lit=\(header.litLength) bss=\(header.bssLength)")

        guard header.instructionCount > 0 && header.codeLength > 0 else {
            Q3Console.shared.print("QVM \(name): invalid header values")
            return false
        }

        self.instructionCount = Int(header.instructionCount)

        // Load code segment
        let codeStart = Int(header.codeOffset)
        let codeLen = Int(header.codeLength)
        guard codeStart + codeLen <= data.count else {
            Q3Console.shared.print("QVM \(name): code segment out of bounds")
            return false
        }
        self.codeBase = Array(data[codeStart..<(codeStart + codeLen)])
        self.codeLength = codeLen

        // Calculate data memory size (round to next power of 2)
        let totalDataSize = Int(header.dataLength) + Int(header.litLength) + Int(header.bssLength)
        var allocSize = 1
        while allocSize < totalDataSize + QVM_STACK_SIZE {
            allocSize *= 2
        }

        self.dataLength = allocSize
        self.dataMask = allocSize - 1
        self.dataBase = Array(repeating: 0, count: allocSize)

        // Copy initialized data
        let dataStart = Int(header.dataOffset)
        let initDataLen = Int(header.dataLength)
        if dataStart + initDataLen <= data.count {
            // Copy and byte-swap the initialized data (long values)
            let longCount = initDataLen / 4
            data.withUnsafeBytes { ptr in
                let src = ptr.baseAddress!.advanced(by: dataStart)
                for i in 0..<longCount {
                    let value = src.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    let le = UInt32(littleEndian: value)
                    withUnsafeBytes(of: le) { bytes in
                        for j in 0..<4 {
                            dataBase[i * 4 + j] = bytes[j]
                        }
                    }
                }
            }
        }

        // Copy literal data (not byte-swapped)
        let litStart = dataStart + initDataLen
        let litLen = Int(header.litLength)
        if litStart + litLen <= data.count && litLen > 0 {
            let destOffset = initDataLen
            data.withUnsafeBytes { ptr in
                let src = ptr.baseAddress!.advanced(by: litStart)
                for i in 0..<litLen {
                    dataBase[destOffset + i] = src.load(fromByteOffset: i, as: UInt8.self)
                }
            }
        }

        // Build instruction pointer table
        guard prepareInterpreter() else {
            Q3Console.shared.print("QVM \(name): failed to prepare interpreter")
            return false
        }

        // Setup stack
        programStack = Int32(dataMask + 1)
        stackBottom = programStack - Int32(QVM_STACK_SIZE)

        Q3Console.shared.print("QVM \(name): loaded successfully (dataSize=\(allocSize), \(instructionCount) instructions)")

        return true
    }

    // MARK: - Prepare Interpreter

    private func prepareInterpreter() -> Bool {
        instructionPointers = Array(repeating: 0, count: instructionCount)

        // First pass: build instruction pointer table
        var pc = 0
        var instruction = 0

        while pc < codeLength && instruction < instructionCount {
            instructionPointers[instruction] = pc
            instruction += 1

            guard pc < codeBase.count else { break }
            let opcodeRaw = codeBase[pc]
            pc += 1

            guard let opcode = QVMOpcode(rawValue: opcodeRaw) else {
                Q3Console.shared.print("QVM \(name): bad opcode \(opcodeRaw) at instruction \(instruction - 1)")
                return false
            }

            if opcode.has4ByteOperand {
                pc += 4
            } else if opcode.has1ByteOperand {
                pc += 1
            }
        }

        if instruction != instructionCount {
            Q3Console.shared.print("QVM \(name): instruction count mismatch: got \(instruction), expected \(instructionCount)")
            return false
        }

        // Second pass: fix branch targets (convert instruction indices to byte offsets)
        pc = 0
        instruction = 0
        while pc < codeLength && instruction < instructionCount {
            let opcodeRaw = codeBase[pc]
            pc += 1
            instruction += 1

            guard let opcode = QVMOpcode(rawValue: opcodeRaw) else { break }

            if opcode.has4ByteOperand {
                // For branch instructions, convert instruction index to byte offset
                switch opcode {
                case .eq, .ne, .lti, .lei, .gti, .gei,
                     .ltu, .leu, .gtu, .geu,
                     .eqf, .nef, .ltf, .lef, .gtf, .gef:
                    let targetInstruction = readInt32(at: pc)
                    if targetInstruction >= 0 && Int(targetInstruction) < instructionCount {
                        writeInt32(at: pc, value: Int32(instructionPointers[Int(targetInstruction)]))
                    }
                default:
                    break
                }
                pc += 4
            } else if opcode.has1ByteOperand {
                pc += 1
            }
        }

        return true
    }

    // MARK: - Data Access Helpers

    func readInt32(fromData offset: Int) -> Int32 {
        let addr = offset & dataMask
        guard addr + 3 < dataBase.count else { return 0 }
        return Int32(dataBase[addr]) |
               (Int32(dataBase[addr + 1]) << 8) |
               (Int32(dataBase[addr + 2]) << 16) |
               (Int32(dataBase[addr + 3]) << 24)
    }

    func writeInt32(toData offset: Int, value: Int32) {
        let addr = offset & dataMask
        guard addr + 3 < dataBase.count else { return }
        dataBase[addr]     = UInt8(truncatingIfNeeded: value)
        dataBase[addr + 1] = UInt8(truncatingIfNeeded: value >> 8)
        dataBase[addr + 2] = UInt8(truncatingIfNeeded: value >> 16)
        dataBase[addr + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    func readUInt16(fromData offset: Int) -> UInt16 {
        let addr = offset & dataMask
        guard addr + 1 < dataBase.count else { return 0 }
        return UInt16(dataBase[addr]) | (UInt16(dataBase[addr + 1]) << 8)
    }

    func readUInt8(fromData offset: Int) -> UInt8 {
        return dataBase[offset & dataMask]
    }

    func writeUInt8(toData offset: Int, value: UInt8) {
        dataBase[offset & dataMask] = value
    }

    func writeUInt16(toData offset: Int, value: UInt16) {
        let addr = offset & dataMask
        guard addr + 1 < dataBase.count else { return }
        dataBase[addr]     = UInt8(truncatingIfNeeded: value)
        dataBase[addr + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    /// Get a pointer into VM data memory
    func dataPointer(at offset: Int32) -> UnsafeMutableRawPointer {
        let addr = Int(offset) & dataMask
        return dataBase.withUnsafeMutableBufferPointer { buf in
            UnsafeMutableRawPointer(buf.baseAddress!.advanced(by: addr))
        }
    }

    /// Read a null-terminated string from VM data memory
    func readString(at offset: Int32) -> String {
        var chars: [UInt8] = []
        var addr = Int(offset) & dataMask
        while addr < dataBase.count {
            let c = dataBase[addr]
            if c == 0 { break }
            chars.append(c)
            addr += 1
        }
        return String(bytes: chars, encoding: .utf8) ?? ""
    }

    /// Write a string into VM data memory
    func writeString(at offset: Int32, _ str: String, maxLen: Int) {
        let bytes = Array(str.utf8)
        let writeLen = min(bytes.count, maxLen - 1)
        for i in 0..<writeLen {
            dataBase[(Int(offset) + i) & dataMask] = bytes[i]
        }
        dataBase[(Int(offset) + writeLen) & dataMask] = 0
    }

    // MARK: - Code Access Helpers

    private func readInt32(at offset: Int) -> Int32 {
        guard offset + 3 < codeBase.count else { return 0 }
        return Int32(codeBase[offset]) |
               (Int32(codeBase[offset + 1]) << 8) |
               (Int32(codeBase[offset + 2]) << 16) |
               (Int32(codeBase[offset + 3]) << 24)
    }

    private func writeInt32(at offset: Int, value: Int32) {
        guard offset + 3 < codeBase.count else { return }
        codeBase[offset]     = UInt8(truncatingIfNeeded: value)
        codeBase[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        codeBase[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        codeBase[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
