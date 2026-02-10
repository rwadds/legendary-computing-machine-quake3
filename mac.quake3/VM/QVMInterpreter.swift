// QVMInterpreter.swift — Stack-based QVM bytecode interpreter

import Foundation

class QVMInterpreter {

    // Maximum operand stack size
    private static let maxOpStackSize = 1024

    // Throttle underflow/overflow errors to avoid log spam
    private static var underflowErrorCount: [String: Int] = [:]
    private static let maxUnderflowErrors = 3

    /// Call a QVM function with up to 10 arguments
    static func call(_ vm: QVM, command: Int32, args: [Int32] = []) -> Int32 {
        guard vm.instructionCount > 0 else {
            Q3Console.shared.print("QVM \(vm.name): not loaded")
            return -1
        }

        // Save current stack
        let savedProgramStack = vm.programStack

        // Q3 VM_Call convention (matching ioquake3):
        // vmMain's ENTER 36, LOCAL 44 reads first param (command) → must be at sp+8
        // LEAVE 36 reads return address from sp+0 → must be -1 sentinel
        // No CALL instruction is used, so no -= 4 adjustment
        vm.programStack &-= 48  // Room for sentinel + command + args

        let sp = Int(vm.programStack)
        vm.writeInt32(toData: sp + 0, value: -1)  // Return sentinel (LEAVE reads this to exit)
        vm.writeInt32(toData: sp + 8, value: command)  // First C parameter of vmMain
        for i in 0..<min(args.count, 10) {
            vm.writeInt32(toData: sp + 12 + i * 4, value: args[i])
        }

        let result = interpret(vm)

        // Restore stack
        vm.programStack = savedProgramStack
        return result
    }

    /// Main interpreter loop
    private static func interpret(_ vm: QVM) -> Int32 {
        // Use UnsafeMutablePointer with padding to avoid Swift Array bounds-check
        // crashes when opStackTop transiently goes out of range within an instruction.
        // The end-of-loop check detects and handles these cases gracefully.
        let opStackPadding = 16
        let opStackBufferSize = maxOpStackSize + opStackPadding * 2
        let opStackRaw = UnsafeMutablePointer<Int32>.allocate(capacity: opStackBufferSize)
        opStackRaw.initialize(repeating: 0, count: opStackBufferSize)
        let opStack = opStackRaw + opStackPadding  // Safe zone for small negative indices
        defer {
            opStackRaw.deinitialize(count: opStackBufferSize)
            opStackRaw.deallocate()
        }
        var opStackTop = 0  // Points to current top
        var pc = 0          // Byte offset into codeBase
        var programStack = vm.programStack

        // Helper to read 4-byte operand from code
        func readCodeInt32() -> Int32 {
            guard pc + 3 < vm.codeBase.count else { return 0 }
            let v = Int32(vm.codeBase[pc]) |
                    (Int32(vm.codeBase[pc + 1]) << 8) |
                    (Int32(vm.codeBase[pc + 2]) << 16) |
                    (Int32(vm.codeBase[pc + 3]) << 24)
            pc += 4
            return v
        }

        // Helper to reinterpret Int32 bits as Float
        func asFloat(_ v: Int32) -> Float {
            return Float(bitPattern: UInt32(bitPattern: v))
        }

        // Helper to reinterpret Float bits as Int32
        func asInt32(_ f: Float) -> Int32 {
            return Int32(bitPattern: f.bitPattern)
        }

        var maxIterations = 100_000_000  // Safety limit

        vm.aborted = false

        while maxIterations > 0 {
            maxIterations -= 1

            if maxIterations == 0 {
                Q3Console.shared.error("QVM \(vm.name): instruction limit hit! pc=\(pc) PS=\(programStack) osTop=\(opStackTop)")
                vm.aborted = true
                break
            }

            if vm.aborted { break }

            guard pc < vm.codeBase.count else {
                Q3Console.shared.error("QVM \(vm.name): PC out of bounds (\(pc) >= \(vm.codeBase.count))")
                break
            }

            let opcodeRaw = vm.codeBase[pc]
            pc += 1

            guard let opcode = QVMOpcode(rawValue: opcodeRaw) else {
                Q3Console.shared.error("QVM \(vm.name): unknown opcode \(opcodeRaw) at pc=\(pc - 1)")
                break
            }

            let instrPC = pc - 1

            switch opcode {
            case .undef, .ignore, .breakOp:
                break

            case .enter:
                let locals = readCodeInt32()
                programStack &-= locals
                // Bounds check
                if programStack < vm.stackBottom {
                    Q3Console.shared.error("QVM \(vm.name): stack overflow")
                    return -1
                }

            case .leave:
                let locals = readCodeInt32()
                programStack &+= locals
                // ioquake3: read return address from PS+0 (no extra PS adjustment)
                let retAddr = vm.readInt32(fromData: Int(programStack))
                if retAddr == -1 {
                    vm.programStack = programStack
                    return opStackTop > 0 ? opStack[opStackTop] : 0
                }
                if retAddr >= 0 && retAddr < Int32(vm.codeLength) {
                    pc = Int(retAddr)
                } else {
                    Q3Console.shared.error("QVM \(vm.name): bad return address \(retAddr)")
                    return -1
                }

            case .call:
                let target = opStack[opStackTop]
                opStackTop -= 1

                // Bounds check programStack before writing
                if programStack < 0 || programStack >= Int32(vm.dataLength) {
                    q3DebugLog("FATAL: programStack OOB in CALL: PS=\(programStack) dataLen=\(vm.dataLength) target=\(target) pc=\(pc) opStackTop=\(opStackTop)", throttle: false)
                    return -1
                }

                // ioquake3: save return address at PS+0 for ALL calls
                vm.writeInt32(toData: Int(programStack), value: Int32(pc))

                if target < 0 {
                    // System call
                    let syscallNum = -1 - target

                    // ioquake3: write syscall number at PS+4
                    vm.writeInt32(toData: Int(programStack) + 4, value: Int32(syscallNum))

                    // Build args starting from PS+4 (matching ioquake3):
                    // args[0] = *(PS+4) = syscallNum
                    // args[1] = *(PS+8) = first real param (from ARG 8)
                    let maxArgs = 13
                    var syscallArgs = [Int32](repeating: 0, count: maxArgs)
                    for i in 0..<maxArgs {
                        syscallArgs[i] = vm.readInt32(fromData: Int(programStack) + 4 + i * 4)
                    }

                    // Save state for recursive VM entry (ioquake3 convention)
                    vm.programStack = programStack &- 4

                    let result: Int32
                    if let handler = vm.systemCall {
                        result = syscallArgs.withUnsafeBufferPointer { buf in
                            handler(buf.baseAddress!, maxArgs, vm)
                        }
                    } else {
                        Q3Console.shared.warning("QVM \(vm.name): syscall \(syscallNum) with no handler")
                        result = 0
                    }

                    // Push result
                    opStackTop += 1
                    if opStackTop >= QVMInterpreter.maxOpStackSize {
                        Q3Console.shared.error("QVM \(vm.name): opStack OVERFLOW at pc=\(pc) opStackTop=\(opStackTop) PS=\(programStack) syscall=\(syscallNum)")
                        q3DebugLog("FATAL: opStack overflow opStackTop=\(opStackTop) syscall=\(syscallNum) pc=\(pc) PS=\(programStack)", throttle: false)
                        return -1
                    }
                    if opStackTop < 0 {
                        Q3Console.shared.error("QVM \(vm.name): opStack UNDERFLOW at pc=\(pc) opStackTop=\(opStackTop)")
                        q3DebugLog("FATAL: opStack underflow opStackTop=\(opStackTop) pc=\(pc)", throttle: false)
                        return -1
                    }
                    opStack[opStackTop] = result
                } else {
                    // Internal function call (ioquake3 convention):
                    // Return address already saved at PS+0 above, no PS adjustment
                    if target >= 0 && Int(target) < vm.instructionCount {
                        pc = vm.instructionPointers[Int(target)]
                    } else {
                        Q3Console.shared.error("QVM \(vm.name): bad call target \(target)")
                        return -1
                    }
                }

            case .push:
                opStackTop += 1
                opStack[opStackTop] = 0

            case .pop:
                opStackTop -= 1

            case .const_:
                let value = readCodeInt32()
                opStackTop += 1
                opStack[opStackTop] = value

            case .local:
                let offset = readCodeInt32()
                opStackTop += 1
                opStack[opStackTop] = offset &+ programStack

            case .jump:
                let target = opStack[opStackTop]
                opStackTop -= 1
                if target >= 0 && Int(target) < vm.instructionCount {
                    pc = vm.instructionPointers[Int(target)]
                } else {
                    Q3Console.shared.error("QVM \(vm.name): bad jump target \(target)")
                    return -1
                }

            // Integer comparisons
            case .eq:
                let target = readCodeInt32()
                let b = opStack[opStackTop]; opStackTop -= 1
                let a = opStack[opStackTop]; opStackTop -= 1
                if a == b { pc = Int(target) }

            case .ne:
                let target = readCodeInt32()
                let b = opStack[opStackTop]; opStackTop -= 1
                let a = opStack[opStackTop]; opStackTop -= 1
                if a != b { pc = Int(target) }

            case .lti:
                let target = readCodeInt32()
                let b = opStack[opStackTop]; opStackTop -= 1
                let a = opStack[opStackTop]; opStackTop -= 1
                if a < b { pc = Int(target) }

            case .lei:
                let target = readCodeInt32()
                let b = opStack[opStackTop]; opStackTop -= 1
                let a = opStack[opStackTop]; opStackTop -= 1
                if a <= b { pc = Int(target) }

            case .gti:
                let target = readCodeInt32()
                let b = opStack[opStackTop]; opStackTop -= 1
                let a = opStack[opStackTop]; opStackTop -= 1
                if a > b { pc = Int(target) }

            case .gei:
                let target = readCodeInt32()
                let b = opStack[opStackTop]; opStackTop -= 1
                let a = opStack[opStackTop]; opStackTop -= 1
                if a >= b { pc = Int(target) }

            case .ltu:
                let target = readCodeInt32()
                let b = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                let a = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                if a < b { pc = Int(target) }

            case .leu:
                let target = readCodeInt32()
                let b = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                let a = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                if a <= b { pc = Int(target) }

            case .gtu:
                let target = readCodeInt32()
                let b = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                let a = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                if a > b { pc = Int(target) }

            case .geu:
                let target = readCodeInt32()
                let b = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                let a = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                if a >= b { pc = Int(target) }

            // Float comparisons
            case .eqf:
                let target = readCodeInt32()
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop]); opStackTop -= 1
                if a == b { pc = Int(target) }

            case .nef:
                let target = readCodeInt32()
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop]); opStackTop -= 1
                if a != b { pc = Int(target) }

            case .ltf:
                let target = readCodeInt32()
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop]); opStackTop -= 1
                if a < b { pc = Int(target) }

            case .lef:
                let target = readCodeInt32()
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop]); opStackTop -= 1
                if a <= b { pc = Int(target) }

            case .gtf:
                let target = readCodeInt32()
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop]); opStackTop -= 1
                if a > b { pc = Int(target) }

            case .gef:
                let target = readCodeInt32()
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop]); opStackTop -= 1
                if a >= b { pc = Int(target) }

            // Memory loads
            case .load1:
                let addr = opStack[opStackTop]
                opStack[opStackTop] = Int32(vm.readUInt8(fromData: Int(addr)))

            case .load2:
                let addr = opStack[opStackTop]
                opStack[opStackTop] = Int32(vm.readUInt16(fromData: Int(addr)))

            case .load4:
                let addr = opStack[opStackTop]
                opStack[opStackTop] = vm.readInt32(fromData: Int(addr))

            // Memory stores
            case .store1:
                let value = opStack[opStackTop]; opStackTop -= 1
                let addr = opStack[opStackTop]; opStackTop -= 1
                vm.writeUInt8(toData: Int(addr), value: UInt8(truncatingIfNeeded: value))

            case .store2:
                let value = opStack[opStackTop]; opStackTop -= 1
                let addr = opStack[opStackTop]; opStackTop -= 1
                vm.writeUInt16(toData: Int(addr), value: UInt16(truncatingIfNeeded: value))

            case .store4:
                let value = opStack[opStackTop]; opStackTop -= 1
                let addr = opStack[opStackTop]; opStackTop -= 1
                vm.writeInt32(toData: Int(addr), value: value)

            case .arg:
                guard pc < vm.codeBase.count else {
                    Q3Console.shared.error("QVM \(vm.name): ARG operand out of bounds pc=\(pc)")
                    return -1
                }
                let offset = Int(vm.codeBase[pc])
                pc += 1
                vm.writeInt32(toData: Int(programStack) + offset, value: opStack[opStackTop])
                opStackTop -= 1

            case .blockCopy:
                let size = Int(readCodeInt32())
                // ioquake3: r0 (top) = source, r1 (second) = destination
                let src = Int(opStack[opStackTop]); opStackTop -= 1
                let dst = Int(opStack[opStackTop]); opStackTop -= 1
                for i in stride(from: size - 1, through: 0, by: -1) {
                    let b = vm.dataBase[(src + i) & vm.dataMask]
                    vm.dataBase[(dst + i) & vm.dataMask] = b
                }

            // Sign extension
            case .sex8:
                let v = Int8(truncatingIfNeeded: opStack[opStackTop])
                opStack[opStackTop] = Int32(v)

            case .sex16:
                let v = Int16(truncatingIfNeeded: opStack[opStackTop])
                opStack[opStackTop] = Int32(v)

            // Integer arithmetic
            case .negi:
                opStack[opStackTop] = 0 &- opStack[opStackTop]

            case .add:
                let b = opStack[opStackTop]; opStackTop -= 1
                opStack[opStackTop] = opStack[opStackTop] &+ b

            case .sub:
                let b = opStack[opStackTop]; opStackTop -= 1
                opStack[opStackTop] = opStack[opStackTop] &- b

            case .divi:
                let b = opStack[opStackTop]; opStackTop -= 1
                if b != 0 {
                    let a = opStack[opStackTop]
                    // Avoid Int32.min / -1 overflow trap (match C wrapping behavior)
                    if a == Int32.min && b == -1 {
                        opStack[opStackTop] = Int32.min
                    } else {
                        opStack[opStackTop] = a / b
                    }
                } else {
                    opStack[opStackTop] = 0
                }

            case .divu:
                let b = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                let a = UInt32(bitPattern: opStack[opStackTop])
                if b != 0 {
                    opStack[opStackTop] = Int32(bitPattern: a / b)
                } else {
                    opStack[opStackTop] = 0
                }

            case .modi:
                let b = opStack[opStackTop]; opStackTop -= 1
                if b != 0 {
                    let a = opStack[opStackTop]
                    // Avoid Int32.min % -1 overflow trap
                    if a == Int32.min && b == -1 {
                        opStack[opStackTop] = 0
                    } else {
                        opStack[opStackTop] = a % b
                    }
                } else {
                    opStack[opStackTop] = 0
                }

            case .modu:
                let b = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                let a = UInt32(bitPattern: opStack[opStackTop])
                if b != 0 {
                    opStack[opStackTop] = Int32(bitPattern: a % b)
                } else {
                    opStack[opStackTop] = 0
                }

            case .muli:
                let b = opStack[opStackTop]; opStackTop -= 1
                opStack[opStackTop] = opStack[opStackTop] &* b

            case .mulu:
                let b = UInt32(bitPattern: opStack[opStackTop]); opStackTop -= 1
                let a = UInt32(bitPattern: opStack[opStackTop])
                opStack[opStackTop] = Int32(bitPattern: a &* b)

            // Bitwise
            case .band:
                let b = opStack[opStackTop]; opStackTop -= 1
                opStack[opStackTop] = opStack[opStackTop] & b

            case .bor:
                let b = opStack[opStackTop]; opStackTop -= 1
                opStack[opStackTop] = opStack[opStackTop] | b

            case .bxor:
                let b = opStack[opStackTop]; opStackTop -= 1
                opStack[opStackTop] = opStack[opStackTop] ^ b

            case .bcom:
                opStack[opStackTop] = ~opStack[opStackTop]

            // Shifts
            case .lsh:
                let b = opStack[opStackTop]; opStackTop -= 1
                let shift = Int(b) & 31
                opStack[opStackTop] = opStack[opStackTop] << shift

            case .rshi:
                let b = opStack[opStackTop]; opStackTop -= 1
                let shift = Int(b) & 31
                opStack[opStackTop] = opStack[opStackTop] >> shift

            case .rshu:
                let b = opStack[opStackTop]; opStackTop -= 1
                let shift = Int(b) & 31
                let a = UInt32(bitPattern: opStack[opStackTop])
                opStack[opStackTop] = Int32(bitPattern: a >> shift)

            // Float arithmetic
            case .negf:
                let f = asFloat(opStack[opStackTop])
                opStack[opStackTop] = asInt32(-f)

            case .addf:
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop])
                opStack[opStackTop] = asInt32(a + b)

            case .subf:
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop])
                opStack[opStackTop] = asInt32(a - b)

            case .divf:
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop])
                opStack[opStackTop] = asInt32(b != 0 ? a / b : 0)

            case .mulf:
                let b = asFloat(opStack[opStackTop]); opStackTop -= 1
                let a = asFloat(opStack[opStackTop])
                opStack[opStackTop] = asInt32(a * b)

            // Type conversions
            case .cvif:
                let i = opStack[opStackTop]
                opStack[opStackTop] = asInt32(Float(i))

            case .cvfi:
                let f = asFloat(opStack[opStackTop])
                if f.isNaN || f.isInfinite {
                    opStack[opStackTop] = 0
                } else if f >= Float(Int32.max) {
                    opStack[opStackTop] = Int32.max
                } else if f <= Float(Int32.min) {
                    opStack[opStackTop] = Int32.min
                } else {
                    opStack[opStackTop] = Int32(f)
                }
            }

            // Stack overflow/underflow check
            if opStackTop < 0 {
                let errCount = QVMInterpreter.underflowErrorCount[vm.name, default: 0]
                if errCount < QVMInterpreter.maxUnderflowErrors {
                    Q3Console.shared.error("QVM \(vm.name): operand stack underflow at pc=\(instrPC) opcode=\(opcode.debugName)")
                } else if errCount == QVMInterpreter.maxUnderflowErrors {
                    Q3Console.shared.error("QVM \(vm.name): suppressing further underflow errors...")
                }
                QVMInterpreter.underflowErrorCount[vm.name] = errCount + 1
                return -1
            }
            if opStackTop >= maxOpStackSize {
                Q3Console.shared.error("QVM \(vm.name): operand stack overflow")
                return -1
            }
        }

        if maxIterations <= 0 {
            Q3Console.shared.error("QVM \(vm.name): exceeded max iterations")
        }

        return opStackTop > 0 ? opStack[opStackTop] : 0
    }

}
