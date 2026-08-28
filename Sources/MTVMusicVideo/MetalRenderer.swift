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
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let ciContext: CIContext
    private let colorPipeline: MTLRenderPipelineState
    private let additiveColorPipeline: MTLRenderPipelineState
    private let radialPipeline: MTLRenderPipelineState
    private let texturePipeline: MTLRenderPipelineState
    private let vignettePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private var retainedCVTexture: CVMetalTexture?
    private var previewTexture: MTLTexture?
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
        guard let colorPipeline = pipeline("fragment_color", blend: alpha),
              let additiveColorPipeline = pipeline("fragment_color", blend: additive),
              let radialPipeline = pipeline("fragment_radial", blend: additive),
              let texturePipeline = pipeline("fragment_texture", blend: alpha),
              let vignettePipeline = pipeline("fragment_vignette", blend: alpha) else { return nil }
        self.colorPipeline = colorPipeline
        self.additiveColorPipeline = additiveColorPipeline
        self.radialPipeline = radialPipeline
        self.texturePipeline = texturePipeline
        self.vignettePipeline = vignettePipeline

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
        lyrics: TextureLayer?
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        prepareVertexBuffer(
            vertexCount: backgrounds.count * 6
                + placeholder.count
                + (darkness > 0.001 ? 6 : 0)
                + (vignetteAlpha > 0 ? 6 : 0)
                + (accentWash.w > 0.001 ? 6 : 0)
                + mesh.soft.count
                + mesh.radials.count
                + mesh.additive.count
                + (lyrics == nil ? 0 : 6)
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = GPUUniforms(size: SIMD2(Float(size.width), Float(size.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 1)

        if backgrounds.isEmpty, !placeholder.isEmpty {
            draw(placeholder, pipeline: colorPipeline, encoder: encoder)
        }
        for layer in backgrounds {
            drawTexturedQuad(layer, encoder: encoder)
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
        if let lyrics {
            drawTexturedQuad(lyrics, encoder: encoder)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func renderToPixelBuffer(_ pixelBuffer: CVPixelBuffer, size: CGSize, backgrounds: [TextureLayer], placeholder: [GPUVertex], darkness: Float, vignetteAlpha: Float, accentWash: SIMD4<Float>, mesh: VisualizerMesh, lyrics: TextureLayer?) -> Bool {
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
            lyrics: lyrics
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

    private func drawTexturedQuad(_ layer: TextureLayer, encoder: MTLRenderCommandEncoder) {
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
        encoder.setRenderPipelineState(texturePipeline)
        encoder.setFragmentTexture(layer.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        draw(vertices, pipeline: texturePipeline, encoder: encoder, setPipeline: false)
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
