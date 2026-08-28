import CoreImage
import CoreVideo
import Foundation
import Metal
import simd

final class MetalRenderer {
    struct TextureLayer {
        let texture: MTLTexture
        let rect: CGRect
        let alpha: Float
        let backgroundReactivity: Float
        let subjectMask: MTLTexture?

        init(texture: MTLTexture, rect: CGRect, alpha: Float, backgroundReactivity: Float = 0, subjectMask: MTLTexture? = nil) {
            self.texture = texture
            self.rect = rect
            self.alpha = alpha
            self.backgroundReactivity = backgroundReactivity
            self.subjectMask = subjectMask
        }
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let ciContext: CIContext
    private let colorPipeline: MTLRenderPipelineState
    private let additiveColorPipeline: MTLRenderPipelineState
    private let radialPipeline: MTLRenderPipelineState
    private let texturePipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let vignettePipeline: MTLRenderPipelineState
    private let postPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private var retainedCVTexture: CVMetalTexture?
    private var previewTexture: MTLTexture?
    private var sceneTexture: MTLTexture?
    private var historyTexture: MTLTexture?
    private var historyValid = false
    private var lastPostTime: Double?
    private var vertexBuffer: MTLBuffer?
    private var vertexBufferCapacity = 0
    private var vertexBufferOffset = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        let ciOptions: [CIContextOption: Any] = [.cacheIntermediates: true]
        self.ciContext = CIContext(mtlDevice: device, options: ciOptions)
        guard let library = try? device.makeLibrary(source: MetalShaders.source, options: nil),
              let vertex = library.makeFunction(name: "vertex_main") else { return nil }

        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float2
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float2
        descriptor.attributes[1].offset = 8
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[2].format = .float4
        descriptor.attributes[2].offset = 16
        descriptor.attributes[2].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<GPUVertex>.stride
        descriptor.layouts[0].stepFunction = .perVertex

        func pipeline(_ fragment: String, blend: Blend) -> MTLRenderPipelineState? {
            guard let fragmentFn = library.makeFunction(name: fragment) else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragmentFn
            desc.vertexDescriptor = descriptor
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = blend.src
            desc.colorAttachments[0].destinationRGBBlendFactor = blend.dst
            desc.colorAttachments[0].sourceAlphaBlendFactor = blend.src
            desc.colorAttachments[0].destinationAlphaBlendFactor = blend.dst
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        let alpha = Blend(src: .one, dst: .oneMinusSourceAlpha)
        let additive = Blend(src: .one, dst: .one)
        let replace = Blend(src: .one, dst: .zero)
        guard let colorPipeline = pipeline("fragment_color", blend: alpha),
              let additiveColorPipeline = pipeline("fragment_color", blend: additive),
              let radialPipeline = pipeline("fragment_radial", blend: additive),
              let texturePipeline = pipeline("fragment_texture", blend: alpha),
              let backgroundPipeline = pipeline("fragment_background", blend: alpha),
              let vignettePipeline = pipeline("fragment_vignette", blend: alpha),
              let postPipeline = pipeline("fragment_post", blend: replace) else { return nil }
        self.colorPipeline = colorPipeline
        self.additiveColorPipeline = additiveColorPipeline
        self.radialPipeline = radialPipeline
        self.texturePipeline = texturePipeline
        self.backgroundPipeline = backgroundPipeline
        self.vignettePipeline = vignettePipeline
        self.postPipeline = postPipeline

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.sampler = sampler
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func makeTexture(width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    func renderCIImage(_ image: CIImage, to texture: MTLTexture) {
        let bounds = image.extent.isInfinite ? CGRect(x: 0, y: 0, width: texture.width, height: texture.height) : image.extent.standardized
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(image, to: texture, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
    }

    func render(
        to texture: MTLTexture,
        size: CGSize,
        backgrounds: [TextureLayer],
        placeholder: [GPUVertex],
        darkness: Float,
        vignetteAlpha: Float,
        accentWash: SIMD4<Float>,
        mesh: VisualizerMesh,
        lyrics: TextureLayer?,
        backgroundMotion: BackgroundMotionSettings,
        postProcess: PostProcessSettings
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let (sceneTexture, historyTexture) = intermediateTextures(size: size) else { return }
        let timeDelta = lastPostTime.map { postProcess.time - $0 }
        if let timeDelta, timeDelta <= 0.001 || timeDelta > 0.20 {
            historyValid = false
        }
        prepareVertexBuffer(
            vertexCount: backgrounds.count * 6
                + placeholder.count
                + (darkness > 0.001 ? 6 : 0)
                + (vignetteAlpha > 0 ? 6 : 0)
                + (accentWash.w > 0.001 ? 6 : 0)
                + mesh.soft.count
                + mesh.radials.count
                + mesh.additive.count
                + 6
                + (lyrics == nil ? 0 : 6)
        )
        if !historyValid {
            let historyPass = MTLRenderPassDescriptor()
            historyPass.colorAttachments[0].texture = historyTexture
            historyPass.colorAttachments[0].loadAction = .clear
            historyPass.colorAttachments[0].storeAction = .store
            historyPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            commandBuffer.makeRenderCommandEncoder(descriptor: historyPass)?.endEncoding()
        }

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneTexture
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { return }

        var uniforms = GPUUniforms(size: SIMD2(Float(size.width), Float(size.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 1)

        if backgrounds.isEmpty, !placeholder.isEmpty {
            draw(placeholder, pipeline: colorPipeline, encoder: encoder)
        }
        for layer in backgrounds {
            drawTexturedQuad(layer, encoder: encoder, backgroundMotion: backgroundMotion, size: size)
        }
        if darkness > 0.001 {
            let color = SIMD4<Float>(0, 0, 0, darkness)
            draw([
                GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: color),
                GPUVertex(position: SIMD2(Float(size.width), 0), uv: SIMD2(1, 0), color: color),
                GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: color),
                GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: color),
                GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: color),
                GPUVertex(position: SIMD2(0, Float(size.height)), uv: SIMD2(0, 1), color: color)
            ], pipeline: colorPipeline, encoder: encoder)
        }
        if vignetteAlpha > 0 {
            let color = SIMD4<Float>(0, 0, 0, vignetteAlpha)
            draw([
                GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: color),
                GPUVertex(position: SIMD2(Float(size.width), 0), uv: SIMD2(1, 0), color: color),
                GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: color),
                GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: color),
                GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: color),
                GPUVertex(position: SIMD2(0, Float(size.height)), uv: SIMD2(0, 1), color: color)
            ], pipeline: vignettePipeline, encoder: encoder)
        }
        if accentWash.w > 0.001 {
            draw([
                GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: accentWash),
                GPUVertex(position: SIMD2(Float(size.width), 0), uv: SIMD2(1, 0), color: accentWash),
                GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: accentWash),
                GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: accentWash),
                GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: accentWash),
                GPUVertex(position: SIMD2(0, Float(size.height)), uv: SIMD2(0, 1), color: accentWash)
            ], pipeline: radialPipeline, encoder: encoder)
        }
        if !mesh.soft.isEmpty {
            draw(mesh.soft, pipeline: colorPipeline, encoder: encoder)
        }
        if !mesh.radials.isEmpty {
            draw(mesh.radials, pipeline: radialPipeline, encoder: encoder)
        }
        if !mesh.additive.isEmpty {
            draw(mesh.additive, pipeline: additiveColorPipeline, encoder: encoder)
        }
        encoder.endEncoding()

        let postPass = MTLRenderPassDescriptor()
        postPass.colorAttachments[0].texture = texture
        postPass.colorAttachments[0].loadAction = .clear
        postPass.colorAttachments[0].storeAction = .store
        postPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let postEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: postPass) else { return }
        postEncoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 1)
        var postUniforms = postProcess.uniforms(size: size, historyValid: historyValid)
        postEncoder.setFragmentBytes(&postUniforms, length: MemoryLayout<GPUPostUniforms>.stride, index: 0)
        postEncoder.setFragmentTexture(sceneTexture, index: 0)
        postEncoder.setFragmentTexture(historyTexture, index: 1)
        postEncoder.setFragmentSamplerState(sampler, index: 0)
        drawFullscreenQuad(size: size, pipeline: postPipeline, encoder: postEncoder)
        postEncoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
                to: historyTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: .init(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        if let lyrics {
            let lyricsPass = MTLRenderPassDescriptor()
            lyricsPass.colorAttachments[0].texture = texture
            lyricsPass.colorAttachments[0].loadAction = .load
            lyricsPass.colorAttachments[0].storeAction = .store
            if let lyricsEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: lyricsPass) {
                lyricsEncoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 1)
                drawTexturedQuad(lyrics, encoder: lyricsEncoder)
                lyricsEncoder.endEncoding()
            }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        historyValid = commandBuffer.status == .completed
        lastPostTime = postProcess.time
    }

    func renderToPixelBuffer(_ pixelBuffer: CVPixelBuffer, size: CGSize, backgrounds: [TextureLayer], placeholder: [GPUVertex], darkness: Float, vignetteAlpha: Float, accentWash: SIMD4<Float>, mesh: VisualizerMesh, lyrics: TextureLayer?, backgroundMotion: BackgroundMotionSettings, postProcess: PostProcessSettings) -> Bool {
        guard let texture = makeTextureFromPixelBuffer(pixelBuffer) else { return false }
        render(
            to: texture,
            size: size,
            backgrounds: backgrounds,
            placeholder: placeholder,
            darkness: darkness,
            vignetteAlpha: vignetteAlpha,
            accentWash: accentWash,
            mesh: mesh,
            lyrics: lyrics,
            backgroundMotion: backgroundMotion,
            postProcess: postProcess
        )
        retainedCVTexture = nil
        return true
    }

    func previewTexture(size: CGSize) -> MTLTexture? {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        if let previewTexture, previewTexture.width == width, previewTexture.height == height {
            return previewTexture
        }
        previewTexture = makeTexture(width: width, height: height)
        return previewTexture
    }

    func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private struct Blend {
        let src: MTLBlendFactor
        let dst: MTLBlendFactor
    }

    private func intermediateTextures(size: CGSize) -> (MTLTexture, MTLTexture)? {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        if sceneTexture?.width != width || sceneTexture?.height != height || historyTexture?.width != width || historyTexture?.height != height {
            sceneTexture = makeTexture(width: width, height: height)
            historyTexture = makeTexture(width: width, height: height)
            historyValid = false
            lastPostTime = nil
        }
        guard let sceneTexture, let historyTexture else { return nil }
        return (sceneTexture, historyTexture)
    }

    private func drawFullscreenQuad(size: CGSize, pipeline: MTLRenderPipelineState, encoder: MTLRenderCommandEncoder) {
        let color = SIMD4<Float>(1, 1, 1, 1)
        draw([
            GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: color),
            GPUVertex(position: SIMD2(Float(size.width), 0), uv: SIMD2(1, 0), color: color),
            GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: color),
            GPUVertex(position: SIMD2(0, 0), uv: SIMD2(0, 0), color: color),
            GPUVertex(position: SIMD2(Float(size.width), Float(size.height)), uv: SIMD2(1, 1), color: color),
            GPUVertex(position: SIMD2(0, Float(size.height)), uv: SIMD2(0, 1), color: color)
        ], pipeline: pipeline, encoder: encoder)
    }

    private func drawTexturedQuad(_ layer: TextureLayer, encoder: MTLRenderCommandEncoder, backgroundMotion: BackgroundMotionSettings? = nil, size: CGSize = .zero) {
        let rect = layer.rect
        let color = SIMD4<Float>(1, 1, 1, layer.alpha)
        let vertices = [
            GPUVertex(position: SIMD2(Float(rect.minX), Float(rect.minY)), uv: SIMD2(0, 0), color: color),
            GPUVertex(position: SIMD2(Float(rect.maxX), Float(rect.minY)), uv: SIMD2(1, 0), color: color),
            GPUVertex(position: SIMD2(Float(rect.maxX), Float(rect.maxY)), uv: SIMD2(1, 1), color: color),
            GPUVertex(position: SIMD2(Float(rect.minX), Float(rect.minY)), uv: SIMD2(0, 0), color: color),
            GPUVertex(position: SIMD2(Float(rect.maxX), Float(rect.maxY)), uv: SIMD2(1, 1), color: color),
            GPUVertex(position: SIMD2(Float(rect.minX), Float(rect.maxY)), uv: SIMD2(0, 1), color: color)
        ]
        let useBackgroundMotion = layer.backgroundReactivity > 0.001 && backgroundMotion != nil
        let pipeline = useBackgroundMotion ? backgroundPipeline : texturePipeline
        encoder.setRenderPipelineState(pipeline)
        if let backgroundMotion, useBackgroundMotion {
            var motionUniforms = backgroundMotion.uniforms(size: size, reactivity: layer.backgroundReactivity, hasVisionMask: layer.subjectMask != nil)
            encoder.setFragmentBytes(&motionUniforms, length: MemoryLayout<GPUBackgroundUniforms>.stride, index: 0)
            encoder.setFragmentTexture(layer.subjectMask ?? layer.texture, index: 1)
        }
        encoder.setFragmentTexture(layer.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        draw(vertices, pipeline: pipeline, encoder: encoder, setPipeline: false)
    }

    private func draw(_ vertices: [GPUVertex], pipeline: MTLRenderPipelineState, encoder: MTLRenderCommandEncoder, setPipeline: Bool = true) {
        guard !vertices.isEmpty else { return }
        if setPipeline { encoder.setRenderPipelineState(pipeline) }
        let byteCount = vertices.count * MemoryLayout<GPUVertex>.stride
        guard let vertexBuffer, vertexBufferOffset + byteCount <= vertexBufferCapacity else { return }
        vertices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                vertexBuffer.contents().advanced(by: vertexBufferOffset).copyMemory(from: base, byteCount: byteCount)
            }
        }
        encoder.setVertexBuffer(vertexBuffer, offset: vertexBufferOffset, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        vertexBufferOffset += byteCount
    }

    private func prepareVertexBuffer(vertexCount: Int) {
        vertexBufferOffset = 0
        let requiredBytes = max(1, vertexCount) * MemoryLayout<GPUVertex>.stride
        if vertexBuffer == nil || vertexBufferCapacity < requiredBytes {
            vertexBufferCapacity = max(requiredBytes, 64 * 1024)
            vertexBuffer = device.makeBuffer(length: vertexBufferCapacity, options: .storageModeShared)
        }
    }

    private func makeTextureFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        CVMetalTextureCacheFlush(textureCache, 0)
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        retainedCVTexture = cvTexture
        return texture
    }
}
