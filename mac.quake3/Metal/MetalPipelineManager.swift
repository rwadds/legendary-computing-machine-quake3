// MetalPipelineManager.swift — Create pipeline states for each blend mode combo

import Foundation
import Metal
import MetalKit

struct PipelineKey: Hashable {
    let srcBlend: UInt32
    let dstBlend: UInt32
    let depthWrite: Bool
    let depthTest: Bool
    let cullMode: Int     // 0=back, 1=front, 2=none
    let alphaTest: UInt32 // GLS_ATEST bits
}

class MetalPipelineManager {
    let device: MTLDevice
    let library: MTLLibrary
    let compiler: MTL4Compiler

    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private(set) var defaultPipeline: MTLRenderPipelineState!
    private(set) var defaultDepthState: MTLDepthStencilState!
    private(set) var pipeline2D: MTLRenderPipelineState!
    private(set) var depthState2D: MTLDepthStencilState!
    private(set) var depthClearPipeline: MTLRenderPipelineState!
    private(set) var depthClearDepthState: MTLDepthStencilState!

    private var depthStates: [String: MTLDepthStencilState] = [:]

    let colorPixelFormat: MTLPixelFormat

    init(device: MTLDevice, view: MTKView) throws {
        self.device = device
        self.colorPixelFormat = view.colorPixelFormat
        self.library = device.makeDefaultLibrary()!
        self.compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

        // Create default depth state
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .lessEqual
        depthDesc.isDepthWriteEnabled = true
        guard let dss = device.makeDepthStencilState(descriptor: depthDesc) else {
            throw NSError(domain: "MetalPipelineManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create default depth stencil state"])
        }
        defaultDepthState = dss

        // Create default pipeline (opaque, depth write, back-face cull)
        defaultPipeline = try getOrCreatePipeline(
            key: PipelineKey(srcBlend: 0, dstBlend: 0, depthWrite: true, depthTest: true, cullMode: 0, alphaTest: 0),
            view: view
        )

        // Create 2D pipeline for UI overlay
        pipeline2D = try make2DPipeline(view: view)

        // Create 2D depth state (no depth test/write)
        let depthDesc2D = MTLDepthStencilDescriptor()
        depthDesc2D.depthCompareFunction = .always
        depthDesc2D.isDepthWriteEnabled = false
        depthState2D = device.makeDepthStencilState(descriptor: depthDesc2D)!

        // Create depth-clear pipeline and depth state
        depthClearPipeline = try makeDepthClearPipeline(view: view)
        let depthClearDesc = MTLDepthStencilDescriptor()
        depthClearDesc.depthCompareFunction = .always
        depthClearDesc.isDepthWriteEnabled = true
        depthClearDepthState = device.makeDepthStencilState(descriptor: depthClearDesc)!
    }

    func getOrCreatePipeline(key: PipelineKey, view: MTKView) throws -> MTLRenderPipelineState {
        if let existing = pipelines[key] { return existing }

        let vertexFuncDesc = MTL4LibraryFunctionDescriptor()
        vertexFuncDesc.library = library
        vertexFuncDesc.name = "q3VertexShader"

        let fragmentFuncDesc = MTL4LibraryFunctionDescriptor()
        fragmentFuncDesc.library = library
        fragmentFuncDesc.name = "q3FragmentShader"

        let pipelineDesc = MTL4RenderPipelineDescriptor()
        pipelineDesc.label = "Q3Pipeline_\(key.hashValue)"
        pipelineDesc.rasterSampleCount = view.sampleCount
        pipelineDesc.vertexFunctionDescriptor = vertexFuncDesc
        pipelineDesc.fragmentFunctionDescriptor = fragmentFuncDesc

        let colorAttachment = pipelineDesc.colorAttachments[0]
        colorAttachment?.pixelFormat = colorPixelFormat

        // Set blending
        if key.srcBlend != 0 || key.dstBlend != 0 {
            colorAttachment?.blendingState = .enabled
            colorAttachment?.sourceRGBBlendFactor = metalBlendFactor(key.srcBlend, isSrc: true)
            colorAttachment?.destinationRGBBlendFactor = metalBlendFactor(key.dstBlend, isSrc: false)
            // Alpha blend: preserve framebuffer alpha (1.0 from clear) so the
            // macOS compositor sees fully-opaque pixels.
            colorAttachment?.sourceAlphaBlendFactor = .zero
            colorAttachment?.destinationAlphaBlendFactor = .one
            colorAttachment?.rgbBlendOperation = .add
            colorAttachment?.alphaBlendOperation = .add
        } else {
            // Opaque pipeline: mask alpha writes to preserve framebuffer alpha (1.0)
            // so the macOS compositor doesn't make the window transparent.
            colorAttachment?.writeMask = [.red, .green, .blue]
        }

        let pipeline = try compiler.makeRenderPipelineState(descriptor: pipelineDesc)
        pipelines[key] = pipeline
        return pipeline
    }

    func getDepthState(write: Bool, test: Bool, equal: Bool = false) -> MTLDepthStencilState {
        let key = "\(write)_\(test)_\(equal)"
        if let existing = depthStates[key] { return existing }

        let desc = MTLDepthStencilDescriptor()
        desc.isDepthWriteEnabled = write
        if test {
            desc.depthCompareFunction = equal ? .equal : .lessEqual
        } else {
            desc.depthCompareFunction = .always
        }
        guard let state = device.makeDepthStencilState(descriptor: desc) else {
            return defaultDepthState
        }
        depthStates[key] = state
        return state
    }

    func pipelineKeyFromStateBits(_ bits: UInt32, cullType: CullType) -> PipelineKey {
        let srcBlend = bits & GLState.srcBlendBits.rawValue
        let dstBlend = (bits & GLState.dstBlendBits.rawValue) >> 4
        let depthWrite = (bits & GLState.depthMaskTrue.rawValue) != 0
        let depthTest = (bits & GLState.depthTestDisable.rawValue) == 0
        let alphaTest = bits & GLState.atestBits.rawValue

        let cullMode: Int
        switch cullType {
        case .frontSided: cullMode = 0
        case .backSided: cullMode = 1
        case .twoSided: cullMode = 2
        }

        return PipelineKey(srcBlend: srcBlend, dstBlend: dstBlend,
                           depthWrite: depthWrite, depthTest: depthTest,
                           cullMode: cullMode, alphaTest: alphaTest)
    }

    func make2DPipeline(view: MTKView) throws -> MTLRenderPipelineState {
        let vertexFuncDesc = MTL4LibraryFunctionDescriptor()
        vertexFuncDesc.library = library
        vertexFuncDesc.name = "q3_2d_vertex"

        let fragmentFuncDesc = MTL4LibraryFunctionDescriptor()
        fragmentFuncDesc.library = library
        fragmentFuncDesc.name = "q3_2d_fragment"

        let pipelineDesc = MTL4RenderPipelineDescriptor()
        pipelineDesc.label = "Q3_2D_Pipeline"
        pipelineDesc.rasterSampleCount = view.sampleCount
        pipelineDesc.vertexFunctionDescriptor = vertexFuncDesc
        pipelineDesc.fragmentFunctionDescriptor = fragmentFuncDesc

        let colorAttachment = pipelineDesc.colorAttachments[0]
        colorAttachment?.pixelFormat = colorPixelFormat

        // Alpha blending for UI elements
        colorAttachment?.blendingState = .enabled
        colorAttachment?.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment?.sourceAlphaBlendFactor = .one
        colorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        colorAttachment?.rgbBlendOperation = .add
        colorAttachment?.alphaBlendOperation = .add

        return try compiler.makeRenderPipelineState(descriptor: pipelineDesc)
    }

    func makeDepthClearPipeline(view: MTKView) throws -> MTLRenderPipelineState {
        let vertexFuncDesc = MTL4LibraryFunctionDescriptor()
        vertexFuncDesc.library = library
        vertexFuncDesc.name = "depthClearVertex"

        let fragmentFuncDesc = MTL4LibraryFunctionDescriptor()
        fragmentFuncDesc.library = library
        fragmentFuncDesc.name = "depthClearFragment"

        let pipelineDesc = MTL4RenderPipelineDescriptor()
        pipelineDesc.label = "DepthClear_Pipeline"
        pipelineDesc.rasterSampleCount = view.sampleCount
        pipelineDesc.vertexFunctionDescriptor = vertexFuncDesc
        pipelineDesc.fragmentFunctionDescriptor = fragmentFuncDesc

        let colorAttachment = pipelineDesc.colorAttachments[0]
        colorAttachment?.pixelFormat = colorPixelFormat
        colorAttachment?.writeMask = []  // No color writes

        return try compiler.makeRenderPipelineState(descriptor: pipelineDesc)
    }

    private func metalBlendFactor(_ bits: UInt32, isSrc: Bool) -> MTLBlendFactor {
        switch bits {
        case 0x01: return .zero
        case 0x02: return .one
        case 0x03: return isSrc ? .destinationColor : .sourceColor
        case 0x04: return isSrc ? .oneMinusDestinationColor : .oneMinusSourceColor
        case 0x05: return .sourceAlpha
        case 0x06: return .oneMinusSourceAlpha
        case 0x07: return .destinationAlpha
        case 0x08: return .oneMinusDestinationAlpha
        case 0x09: return .sourceAlphaSaturated
        default: return isSrc ? .one : .zero
        }
    }
}
