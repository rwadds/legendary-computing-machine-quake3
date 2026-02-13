// ShaderParser.swift — Parse .shader script files from pk3s

import Foundation

class ShaderParser {
    static let shared = ShaderParser()

    private var shaderDefs: [String: Q3ShaderDef] = [:]
    private var loaded = false

    private init() {}

    /// Debug: return sample shader definition keys
    func sampleNames(count: Int = 10) -> [String] {
        return Array(shaderDefs.keys.sorted().prefix(count))
    }

    var definitionCount: Int { shaderDefs.count }

    func loadAllShaders() {
        guard !loaded else { return }
        loaded = true

        let shaderFiles = Q3FileSystem.shared.listFiles(inDirectory: "scripts", withExtension: "shader")
        Q3Console.shared.print("Loading \(shaderFiles.count) shader files...")

        var loadedFileCount = 0
        var failedFileCount = 0
        for file in shaderFiles {
            if let data = Q3FileSystem.shared.loadFile(file),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                parseShaderFile(text, fileName: file)
                loadedFileCount += 1
            } else {
                failedFileCount += 1
            }
        }

        Q3Console.shared.print("Loaded \(shaderDefs.count) shader definitions (\(loadedFileCount) files ok, \(failedFileCount) failed)")
    }

    func findShader(_ name: String) -> Q3ShaderDef? {
        let key = name.lowercased()
        if let def = shaderDefs[key] { return def }
        // MD3 models often store shader names with .tga/.jpg extension but
        // shader scripts define them without — strip extension and retry
        let base = (key as NSString).deletingPathExtension
        if base != key, let def = shaderDefs[base] { return def }
        return nil
    }

    // MARK: - Shader File Parsing

    private func parseShaderFile(_ text: String, fileName: String) {
        var tokens = ShaderTokenizer(text: text)

        while let shaderName = tokens.next() {
            // Expect opening brace
            guard let brace = tokens.next(), brace == "{" else { continue }

            var shader = Q3ShaderDef()
            shader.name = shaderName.lowercased()
            shader.explicitlyDefined = true

            parseShaderBody(&shader, tokens: &tokens)

            shaderDefs[shader.name] = shader
        }
    }

    private func parseShaderBody(_ shader: inout Q3ShaderDef, tokens: inout ShaderTokenizer) {
        var depth = 1

        while let token = tokens.next() {
            if token == "{" {
                // Start of a stage
                var stage = ShaderStage()
                stage.active = true
                parseStage(&stage, tokens: &tokens)
                shader.stages.append(stage)
                continue
            }
            if token == "}" {
                depth -= 1
                if depth <= 0 { break }
                continue
            }

            let lower = token.lowercased()

            switch lower {
            case "cull":
                if let val = tokens.next()?.lowercased() {
                    switch val {
                    case "none", "twosided", "disable": shader.cullType = .twoSided
                    case "back", "backside", "backsided": shader.cullType = .backSided
                    default: shader.cullType = .frontSided
                    }
                }

            case "nomipmaps":
                shader.noMipMaps = true
                shader.noPicMip = true

            case "nopicmip":
                shader.noPicMip = true

            case "polygonoffset":
                shader.polygonOffset = true

            case "entitymergable":
                shader.entityMergable = true

            case "sort":
                if let val = tokens.next()?.lowercased() {
                    switch val {
                    case "portal": shader.sort = ShaderSort.portal.rawValue
                    case "sky": shader.sort = ShaderSort.environment.rawValue
                    case "opaque": shader.sort = ShaderSort.opaque.rawValue
                    case "decal": shader.sort = ShaderSort.decal.rawValue
                    case "seethrough": shader.sort = ShaderSort.seeThrough.rawValue
                    case "banner": shader.sort = ShaderSort.banner.rawValue
                    case "underwater": shader.sort = ShaderSort.underwater.rawValue
                    case "additive": shader.sort = ShaderSort.blend1.rawValue
                    case "nearest": shader.sort = ShaderSort.nearest.rawValue
                    default:
                        if let f = Float(val) { shader.sort = f }
                    }
                }

            case "surfaceparm":
                _ = tokens.next()  // consume surfaceparm value (used for compile-time flags)

            case "skyparms":
                shader.isSky = true
                shader.sort = ShaderSort.environment.rawValue
                if let farBox = tokens.next() {
                    if farBox != "-" {
                        shader.skyBoxNames = ["_rt", "_bk", "_lf", "_ft", "_up", "_dn"].map { farBox + $0 }
                    }
                }
                if let cloudHeight = tokens.next() {
                    shader.cloudHeight = Float(cloudHeight) ?? 512
                }
                _ = tokens.next()  // near box (usually "-")

            case "fogparms":
                // fogparms ( r g b ) depthForOpaque
                _ = tokens.next()  // (
                if let r = tokens.next(), let g = tokens.next(), let b = tokens.next() {
                    shader.fogColor = Vec3(Float(r) ?? 0, Float(g) ?? 0, Float(b) ?? 0)
                }
                _ = tokens.next()  // )
                if let d = tokens.next() {
                    shader.fogDepthForOpaque = Float(d) ?? 0
                }

            case "deformvertexes":
                if let typeStr = tokens.next()?.lowercased() {
                    var deform = DeformStage()
                    switch typeStr {
                    case "wave":
                        deform.deformation = .wave
                        let spread = Float(tokens.next() ?? "0") ?? 0
                        deform.deformationSpread = spread != 0 ? 1.0 / spread : 100
                        deform.deformationWave = parseWaveform(&tokens)
                    case "normal":
                        deform.deformation = .normals
                        deform.deformationWave.amplitude = Float(tokens.next() ?? "0") ?? 0
                        deform.deformationWave.frequency = Float(tokens.next() ?? "0") ?? 0
                    case "bulge":
                        deform.deformation = .bulge
                        deform.bulgeWidth = Float(tokens.next() ?? "0") ?? 0
                        deform.bulgeHeight = Float(tokens.next() ?? "0") ?? 0
                        deform.bulgeSpeed = Float(tokens.next() ?? "0") ?? 0
                    case "move":
                        deform.deformation = .move
                        let mx = Float(tokens.next() ?? "0") ?? 0
                        let my = Float(tokens.next() ?? "0") ?? 0
                        let mz = Float(tokens.next() ?? "0") ?? 0
                        deform.moveVector = Vec3(mx, my, mz)
                        deform.deformationWave = parseWaveform(&tokens)
                    case "autosprite":
                        deform.deformation = .autosprite
                    case "autosprite2":
                        deform.deformation = .autosprite2
                    case "projectionshadow":
                        deform.deformation = .projectionShadow
                    default:
                        break
                    }
                    if deform.deformation != .none {
                        shader.deforms.append(deform)
                    }
                }

            case "portal":
                shader.sort = ShaderSort.portal.rawValue

            case "q3map_sun", "q3map_surfacelight", "q3map_lightimage", "q3map_lightsubdivide",
                 "q3map_backsplash", "q3map_globaltexture", "q3map_tesssize",
                 "q3map_lightmapsamplesize", "q3map_flare", "light",
                 "tesssize", "qer_editorimage", "qer_nocarve", "qer_trans":
                _ = tokens.next()  // consume value

            default:
                break
            }
        }

        // Auto-determine sort if not set explicitly
        if shader.sort == ShaderSort.opaque.rawValue && !shader.stages.isEmpty {
            let firstBits = shader.stages[0].stateBits
            let srcBlend = firstBits & GLState.srcBlendBits.rawValue
            let dstBlend = firstBits & GLState.dstBlendBits.rawValue

            if srcBlend != 0 || dstBlend != 0 {
                shader.sort = ShaderSort.seeThrough.rawValue
            }
        }

        // Finalize multi-stage shaders: stages after the first must use depthFunc=equal
        // to avoid z-fighting when drawing the same surface multiple times.
        // Q3's original renderer does this in FinishShader / ComputeStageIteratorFunc.
        if shader.stages.count > 1 {
            let firstBits = shader.stages[0].stateBits
            let firstWritesDepth = (firstBits & GLState.depthMaskTrue.rawValue) != 0
            let firstHasBlend = (firstBits & (GLState.srcBlendBits.rawValue | GLState.dstBlendBits.rawValue)) != 0

            // If the first stage is opaque (writes depth, no blend), subsequent stages
            // need depthFunc=equal so they render at the exact same depth
            if firstWritesDepth || !firstHasBlend {
                for i in 1..<shader.stages.count {
                    let alreadyEqual = (shader.stages[i].stateBits & GLState.depthFuncEqual.rawValue) != 0
                    if !alreadyEqual {
                        shader.stages[i].stateBits |= GLState.depthFuncEqual.rawValue
                    }
                }
            }
        }
    }

    private func parseStage(_ stage: inout ShaderStage, tokens: inout ShaderTokenizer) {
        while let token = tokens.next() {
            if token == "}" { break }

            let lower = token.lowercased()

            switch lower {
            case "map":
                if let texName = tokens.next() {
                    if texName == "$lightmap" {
                        stage.bundles[0].isLightmap = true
                        stage.bundles[0].tcGen = .lightmap
                    } else if texName == "$whiteimage" {
                        stage.bundles[0].imageNames = ["*white"]
                    } else {
                        stage.bundles[0].imageNames = [texName]
                    }
                }

            case "clampmap":
                if let texName = tokens.next() {
                    stage.bundles[0].imageNames = [texName]
                }

            case "animmap":
                if let speed = tokens.next() {
                    stage.bundles[0].imageAnimationSpeed = Float(speed) ?? 0
                    var names: [String] = []
                    while let name = tokens.peek(), name != "}" && !isStageKeyword(name) {
                        names.append(tokens.next()!)
                    }
                    stage.bundles[0].imageNames = names
                }

            case "blendfunc":
                if let val = tokens.next()?.lowercased() {
                    switch val {
                    case "add":
                        stage.stateBits |= GLState.srcBlendOne.rawValue | GLState.dstBlendOne.rawValue
                    case "filter":
                        stage.stateBits |= GLState.srcBlendDstColor.rawValue | GLState.dstBlendZero.rawValue
                    case "blend":
                        stage.stateBits |= GLState.srcBlendSrcAlpha.rawValue | GLState.dstBlendOneMinusSrcAlpha.rawValue
                    default:
                        let srcBits = parseBlendFactor(val, isSrc: true)
                        if let dstStr = tokens.next()?.lowercased() {
                            let dstBits = parseBlendFactor(dstStr, isSrc: false)
                            stage.stateBits |= srcBits | dstBits
                        }
                    }
                    // Clear depth mask for blended stages
                    stage.stateBits &= ~GLState.depthMaskTrue.rawValue
                }

            case "alphafunc":
                if let val = tokens.next()?.lowercased() {
                    switch val {
                    case "gt0": stage.stateBits |= GLState.atestGT0.rawValue
                    case "lt128": stage.stateBits |= GLState.atestLT80.rawValue
                    case "ge128": stage.stateBits |= GLState.atestGE80.rawValue
                    default: break
                    }
                }

            case "depthwrite":
                stage.stateBits |= GLState.depthMaskTrue.rawValue

            case "depthfunc":
                if let val = tokens.next()?.lowercased() {
                    if val == "equal" {
                        stage.stateBits |= GLState.depthFuncEqual.rawValue
                    }
                }

            case "rgbgen":
                if let val = tokens.next()?.lowercased() {
                    switch val {
                    case "identity": stage.rgbGen = .identity
                    case "identitylighting": stage.rgbGen = .identityLighting
                    case "entity": stage.rgbGen = .entity
                    case "oneminusentity": stage.rgbGen = .oneMinusEntity
                    case "vertex": stage.rgbGen = .vertex
                    case "exactvertex": stage.rgbGen = .exactVertex
                    case "oneminusvertex": stage.rgbGen = .oneMinusVertex
                    case "lightingdiffuse": stage.rgbGen = .lightingDiffuse
                    case "wave":
                        stage.rgbGen = .waveform
                        stage.rgbWave = parseWaveform(&tokens)
                    case "const":
                        stage.rgbGen = .const_
                        _ = tokens.next()  // (
                        let r = Float(tokens.next() ?? "1") ?? 1
                        let g = Float(tokens.next() ?? "1") ?? 1
                        let b = Float(tokens.next() ?? "1") ?? 1
                        _ = tokens.next()  // )
                        stage.constantColor.x = r
                        stage.constantColor.y = g
                        stage.constantColor.z = b
                    default: break
                    }
                }

            case "alphagen":
                if let val = tokens.next()?.lowercased() {
                    switch val {
                    case "identity": stage.alphaGen = .identity
                    case "entity": stage.alphaGen = .entity
                    case "oneminusentity": stage.alphaGen = .oneMinusEntity
                    case "vertex": stage.alphaGen = .vertex
                    case "oneminusvertex": stage.alphaGen = .oneMinusVertex
                    case "lightingspecular": stage.alphaGen = .lightingSpecular
                    case "portal":
                        stage.alphaGen = .portal
                        _ = tokens.next()  // range
                    case "wave":
                        stage.alphaGen = .waveform
                        stage.alphaWave = parseWaveform(&tokens)
                    case "const":
                        stage.alphaGen = .const_
                        let a = Float(tokens.next() ?? "1") ?? 1
                        stage.constantColor.w = a
                    default: break
                    }
                }

            case "tcgen":
                if let val = tokens.next()?.lowercased() {
                    switch val {
                    case "texture": stage.bundles[0].tcGen = .texture
                    case "lightmap": stage.bundles[0].tcGen = .lightmap
                    case "environment": stage.bundles[0].tcGen = .environmentMapped
                    case "vector":
                        stage.bundles[0].tcGen = .vector
                        // Parse two vectors
                        _ = tokens.next()  // (
                        let sx = Float(tokens.next() ?? "0") ?? 0
                        let sy = Float(tokens.next() ?? "0") ?? 0
                        let sz = Float(tokens.next() ?? "0") ?? 0
                        _ = tokens.next()  // )
                        _ = tokens.next()  // (
                        let tx = Float(tokens.next() ?? "0") ?? 0
                        let ty = Float(tokens.next() ?? "0") ?? 0
                        let tz = Float(tokens.next() ?? "0") ?? 0
                        _ = tokens.next()  // )
                        stage.bundles[0].tcGenVectors = (Vec3(sx, sy, sz), Vec3(tx, ty, tz))
                    default: break
                    }
                }

            case "tcmod":
                if let val = tokens.next()?.lowercased() {
                    var mod = TexModInfo()
                    switch val {
                    case "scroll":
                        mod.type = .scroll
                        mod.scroll.x = Float(tokens.next() ?? "0") ?? 0
                        mod.scroll.y = Float(tokens.next() ?? "0") ?? 0
                    case "scale":
                        mod.type = .scale
                        mod.scale.x = Float(tokens.next() ?? "1") ?? 1
                        mod.scale.y = Float(tokens.next() ?? "1") ?? 1
                    case "rotate":
                        mod.type = .rotate
                        mod.rotateSpeed = Float(tokens.next() ?? "0") ?? 0
                    case "stretch":
                        mod.type = .stretch
                        mod.wave = parseWaveform(&tokens)
                    case "turb":
                        mod.type = .turbulent
                        // Q3 turb takes 4 values (base, amp, phase, freq) — no function name.
                        // Using parseWaveform here would consume an extra token (the closing brace).
                        mod.wave.func_ = .sin
                        mod.wave.base = Float(tokens.next() ?? "0") ?? 0
                        mod.wave.amplitude = Float(tokens.next() ?? "0") ?? 0
                        mod.wave.phase = Float(tokens.next() ?? "0") ?? 0
                        mod.wave.frequency = Float(tokens.next() ?? "0") ?? 0
                    case "transform":
                        mod.type = .transform
                        mod.matrix.0.0 = Float(tokens.next() ?? "1") ?? 1
                        mod.matrix.0.1 = Float(tokens.next() ?? "0") ?? 0
                        mod.matrix.1.0 = Float(tokens.next() ?? "0") ?? 0
                        mod.matrix.1.1 = Float(tokens.next() ?? "1") ?? 1
                        mod.translate.x = Float(tokens.next() ?? "0") ?? 0
                        mod.translate.y = Float(tokens.next() ?? "0") ?? 0
                    case "entitytranslate":
                        mod.type = .entityTranslate
                    default: break
                    }
                    stage.bundles[0].texMods.append(mod)
                }

            case "detail":
                stage.isDetail = true

            default:
                break
            }
        }
    }

    // MARK: - Parse Helpers

    private func parseWaveform(_ tokens: inout ShaderTokenizer) -> WaveForm {
        var wave = WaveForm()
        if let funcStr = tokens.next()?.lowercased() {
            switch funcStr {
            case "sin": wave.func_ = .sin
            case "square": wave.func_ = .square
            case "triangle": wave.func_ = .triangle
            case "sawtooth": wave.func_ = .sawtooth
            case "inversesawtooth": wave.func_ = .inverseSawtooth
            case "noise": wave.func_ = .noise
            default: break
            }
        }
        wave.base = Float(tokens.next() ?? "0") ?? 0
        wave.amplitude = Float(tokens.next() ?? "0") ?? 0
        wave.phase = Float(tokens.next() ?? "0") ?? 0
        wave.frequency = Float(tokens.next() ?? "0") ?? 0
        return wave
    }

    private func parseBlendFactor(_ str: String, isSrc: Bool) -> UInt32 {
        let shift: UInt32 = isSrc ? 0 : 4
        switch str {
        case "gl_zero": return 0x01 << shift
        case "gl_one": return 0x02 << shift
        case "gl_dst_color", "gl_src_color":
            return 0x03 << shift
        case "gl_one_minus_dst_color", "gl_one_minus_src_color":
            return 0x04 << shift
        case "gl_src_alpha": return 0x05 << shift
        case "gl_one_minus_src_alpha": return 0x06 << shift
        case "gl_dst_alpha": return 0x07 << shift
        case "gl_one_minus_dst_alpha": return 0x08 << shift
        case "gl_alpha_saturate": return isSrc ? 0x09 : 0
        default: return 0
        }
    }

    private func isStageKeyword(_ token: String) -> Bool {
        let keywords = ["map", "clampmap", "animmap", "blendfunc", "alphafunc",
                        "depthwrite", "depthfunc", "rgbgen", "alphagen",
                        "tcgen", "tcmod", "detail"]
        return keywords.contains(token.lowercased())
    }
}

// MARK: - Shader Tokenizer

struct ShaderTokenizer {
    private let text: String
    private var index: String.Index

    init(text: String) {
        // Normalize CRLF → LF. Swift treats \r\n as a single Character
        // that doesn't match "\n" or "\r" individually, breaking tokenization.
        self.text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        self.index = self.text.startIndex
    }

    mutating func next() -> String? {
        skipWhitespaceAndComments()
        guard index < text.endIndex else { return nil }

        if text[index] == "{" || text[index] == "}" {
            let ch = String(text[index])
            index = text.index(after: index)
            return ch
        }

        if text[index] == "\"" {
            return readQuotedString()
        }

        return readToken()
    }

    func peek() -> String? {
        var copy = self
        return copy.next()
    }

    private mutating func skipWhitespaceAndComments() {
        while index < text.endIndex {
            let ch = text[index]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                index = text.index(after: index)
                continue
            }
            // Line comment
            if ch == "/" {
                let next = text.index(after: index)
                if next < text.endIndex && text[next] == "/" {
                    // Skip to end of line
                    while index < text.endIndex && text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                // Block comment
                if next < text.endIndex && text[next] == "*" {
                    index = text.index(index, offsetBy: 2)
                    while index < text.endIndex {
                        if text[index] == "*" {
                            let next2 = text.index(after: index)
                            if next2 < text.endIndex && text[next2] == "/" {
                                index = text.index(next2, offsetBy: 1)
                                break
                            }
                        }
                        index = text.index(after: index)
                    }
                    continue
                }
            }
            break
        }
    }

    private mutating func readQuotedString() -> String {
        index = text.index(after: index) // skip opening quote
        var result = ""
        while index < text.endIndex && text[index] != "\"" {
            result.append(text[index])
            index = text.index(after: index)
        }
        if index < text.endIndex { index = text.index(after: index) } // skip closing quote
        return result
    }

    private mutating func readToken() -> String {
        var result = ""
        while index < text.endIndex {
            let ch = text[index]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "{" || ch == "}" { break }
            result.append(ch)
            index = text.index(after: index)
        }
        return result
    }
}
