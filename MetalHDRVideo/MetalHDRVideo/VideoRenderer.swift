import Metal
import MetalKit
import AVFoundation
import CoreVideo
import CoreMedia

enum TonemappingMode {
    case edr
    case auto
}

class VideoRenderer : NSObject, RenderDelegate {
    let asset: AVAsset
    let tonemappingMode: TonemappingMode = .auto

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private var renderPipelineState: MTLRenderPipelineState!
    private var view: MTKView?
    private var targetPixelFormat = MTLPixelFormat.invalid
    private var videoOutput: AVPlayerItemVideoOutput?
    private var textureMappingsInFlight: Set<CVMetalTexture> = []
    private var assetIsHDR: Bool = false
    private var contentSize: CGSize = .zero
    private var videoTransform: CGAffineTransform = .identity
    private var currentEDRHeadroom: CGFloat = 1.1

    init(url: URL) {
        self.asset = AVURLAsset(url: url)

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        var textureCache: CVMetalTextureCache!
        let _ = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        self.textureCache = textureCache

        super.init()
    }

    func prepareToPlay(_ onReady: @escaping (AVPlayerItem) -> Void) {
        guard let view = view else { return }
        guard let metalLayer = view.layer as? CAMetalLayer else { return }

        reportMaxEDRHeadroom()

        Task.init { @MainActor in
            let videoTracks = try await asset.loadTracks(withMediaCharacteristic: .visual)
            if videoTracks.isEmpty { return }

            let hdrTracks = try await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)

            self.assetIsHDR = !hdrTracks.isEmpty

            let firstTrack = videoTracks[0]
            self.contentSize = try await firstTrack.load(.naturalSize)
            self.videoTransform = try await firstTrack.load(.preferredTransform)

            var outputTransferFunction = AVVideoTransferFunction_Linear
            if tonemappingMode == .auto {
                let formatDescriptions = try await firstTrack.load(.formatDescriptions)
                if let primaryFormatDescription = formatDescriptions.first {
                    if let transferFunctionValue = primaryFormatDescription.extensions[.transferFunction] {
                        let transferFunction = transferFunctionValue.propertyListRepresentation as! CFString
                        if transferFunction == CMFormatDescription.Extensions.Value.TransferFunction.itu_R_2020.rawValue {
                            // ITU_R_2020 requires special handling because there is no matching AVFoundation value for it.
                            // All of the other relevant transfer functions are spelled identically between CM and AV.
                            outputTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                        } else {
                            outputTransferFunction = transferFunction as String
                        }
                        print("Selected output transfer function: \(outputTransferFunction)")
                    }
                }
                if formatDescriptions.count > 1 {
                    print("Not handling multiple video format descriptions")
                }
            }

            self.setInitialEDRMetadata()

            self.targetPixelFormat = .rgba16Float

            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
            metalLayer.pixelFormat = targetPixelFormat

            let videoColorProperties = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: outputTransferFunction,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
            let outputVideoSettings: [String : Any] = [
                AVVideoAllowWideColorKey: true,
                AVVideoColorPropertiesKey: videoColorProperties,
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_64RGBAHalf)
            ]
            self.videoOutput = AVPlayerItemVideoOutput(outputSettings: outputVideoSettings)

            self.renderPipelineState = makeRenderPipeline(outputTransferFunction)

            let playerItem = AVPlayerItem(asset: asset)
            playerItem.add(videoOutput!)

            onReady(playerItem)
        }
    }

    func configure(view: MTKView) {
        self.view = view
        view.device = self.device
        view.delegate = self
        view.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    private var logOnce: Bool = true

    func draw(in view: MTKView) {
        guard let videoOutput = videoOutput else { return }

        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())

        if !videoOutput.hasNewPixelBuffer(forItemTime: itemTime) { return }

        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime,
                                                            itemTimeForDisplay: nil) else { return }

        let textureWidth = CVPixelBufferGetWidth(pixelBuffer)
        let textureHeight = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let _ = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                          textureCache,
                                                          pixelBuffer,
                                                          nil,
                                                          targetPixelFormat,
                                                          textureWidth,
                                                          textureHeight,
                                                          0,
                                                          &cvTexture)
        guard let cvTexture else { return }

        if (tonemappingMode == .edr) && CAEDRMetadata.isAvailable {
            let metalLayer = view.layer as? CAMetalLayer
            let imageBuffer: CVBuffer = pixelBuffer
            // Look for HLG metadata
            let ambientViewingInfo = CVBufferCopyAttachment(imageBuffer, kCVImageBufferAmbientViewingEnvironmentKey, nil)
            if let ambientViewingInfo {
                if #available(iOS 17.0, macOS 14.0, *) {
                    metalLayer?.edrMetadata = CAEDRMetadata.hlg(ambientViewingEnvironment: (ambientViewingInfo as! Data))
                } else {
                    metalLayer?.edrMetadata = CAEDRMetadata.hlg
                }
                if logOnce {
                    print("Asset had HLG metadata")
                    logOnce = false
                }
            }
            // Look for HDR10 metadata
            let masteringColorVolume = CVBufferCopyAttachment(imageBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil)
            let contentLightLevel = CVBufferCopyAttachment(imageBuffer, kCVImageBufferContentLightLevelInfoKey, nil)
            if let masteringColorVolume, let contentLightLevel {
                metalLayer?.edrMetadata = CAEDRMetadata.hdr10(displayInfo: (masteringColorVolume as! Data),
                                                              contentInfo: (contentLightLevel as! Data),
                                                              opticalOutputScale: 100.0)
                if logOnce {
                    print("Asset had HDR10 metadata")
                    logOnce = false
                }
            }
        }

        guard let frameTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!

        guard let passDescriptor = view.currentRenderPassDescriptor else { return }

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)!
        renderEncoder.setRenderPipelineState(renderPipelineState)

        var modelProjectionMatrix = displayTransform(frameSize: CGSize(width: textureWidth, height: textureHeight),
                                                     contentTransform: videoTransform,
                                                     displaySize: view.drawableSize)
        renderEncoder.setVertexBytes(&modelProjectionMatrix, length: MemoryLayout<float4x4>.stride, index: 0)

        if tonemappingMode == .auto {
            pollCurrentEDRHeadroom()
            var edrHeadroom = Float(currentEDRHeadroom)
            renderEncoder.setFragmentBytes(&edrHeadroom, length: MemoryLayout<Float>.size, index: 0)
        }

        renderEncoder.setFragmentTexture(frameTexture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.present(view.currentDrawable!)

        // We must keep the CVMetalTexture alive while its Metal texture is in use, because
        // it prevents the texture and its underlying IOSurface from being recycled.
        textureMappingsInFlight.insert(cvTexture)
        commandBuffer.addCompletedHandler { [weak self] _ in
            // Completed handlers can be called on an arbitrary thread, so re-dispatch to main to avoid data races.
            Task.init { @MainActor in
                self?.textureMappingsInFlight.remove(cvTexture)
            }
        }

        commandBuffer.commit()
    }

    private func makeRenderPipeline(_ transferFunction: String) -> MTLRenderPipelineState {
        let fragmentFunctionName = switch transferFunction {
        case AVVideoTransferFunction_SMPTE_ST_2084_PQ:
            "fragment_tonemap_pq"
        case AVVideoTransferFunction_ITU_R_2100_HLG:
            "fragment_tonemap_hlg"
        default: 
            "fragment_linear"
        }

        let library = device.makeDefaultLibrary()!
        let vertexFunction = library.makeFunction(name: "vertex_main")!
        let fragmentFunction = library.makeFunction(name: fragmentFunctionName)!

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.vertexFunction = vertexFunction
        renderPipelineDescriptor.fragmentFunction = fragmentFunction
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = targetPixelFormat
        do {
            return try device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
        } catch {
            fatalError("Failed to create render pipeline state: \(error)")
        }
    }

    private func displayTransform(frameSize: CGSize,
                                  contentTransform: CGAffineTransform,
                                  displaySize: CGSize) -> simd_float4x4
    {
        // The natural frame of a video track is the bounding rect of the image containing a frame's contents.
        let naturalFrame = CGRectMake(0, 0, frameSize.width, frameSize.height)
        // The video frame is the bounding rect of a frame after transformation by the track's preferred transform.
        let videoFrame = CGRectApplyAffineTransform(naturalFrame, contentTransform)
        // Vertices in the vertex shader are the corners of a canonical (unit) square; this transform reshapes
        // that square so its size matches the natural frame of the video.
        let naturalFromCanonicalTransform = CGAffineTransformMakeScale(frameSize.width, frameSize.height)
        // Concatenating the preferred transform of the video with the natural-from-canonical transform produces
        // a transform that scales, rotates, and translates the unit square into the final video frame size and orientation.
        let videoFromCanonicalTransform = CGAffineTransformConcat(naturalFromCanonicalTransform, contentTransform)
        let videoFrameMatrix = simd_float4x4(videoFromCanonicalTransform)
        // To display the video in an aspect-correct manner, we transform the bounds of the video frame
        // so that they fit tightly within the bounding rect of the surface to be presented.
        let displayBounds = CGRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height)
        let modelMatrix = transformForAspectFitting(videoFrame, in: displayBounds)
        // The projection matrix takes us from coordinates expressed relative to the presentation surface's bounds
        // into clip space.
        let projectionMatrix = float4x4.orthographicProjection(left: 0,
                                                               top: 0,
                                                               right: Float(displayBounds.width),
                                                               bottom: Float(displayBounds.height),
                                                               near: -1,
                                                               far: 1)
        // The final model–projection matrix combines the effects of the above transforms.
        let videoTransform = projectionMatrix * modelMatrix * videoFrameMatrix
        return videoTransform
    }

    private func reportMaxEDRHeadroom() {
        var maxHeadroom: CGFloat = 1.0
#if os(macOS)
        maxHeadroom = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
#elseif os(iOS)
        maxHeadroom = UIScreen.main.potentialEDRHeadroom
#endif
        if maxHeadroom > 1.0 {
            print("The main display supports EDR with a maximum headroom of \(maxHeadroom).")
        } else {
            print("The main display does NOT support EDR.")
        }
    }

    private func pollCurrentEDRHeadroom() {
#if os (macOS)
        let screen = self.view?.window?.screen ?? NSScreen.main
        let headroom = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
#elseif os(iOS)
        let screen = self.view?.window?.screen ?? UIScreen.main
        let headroom = screen.currentEDRHeadroom
#else
        let headroom: CGFloat = 1.0
#endif
        if headroom != currentEDRHeadroom {
            print("EDR headrooom changed to \(headroom)")
            currentEDRHeadroom = headroom
        }
    }

    private func setInitialEDRMetadata() {
        guard let metalLayer = view?.layer as? CAMetalLayer else {
            print("Tried to set initial EDR metadata before view was configured")
            return
        }

        if (tonemappingMode == .edr) && assetIsHDR && metalLayer.edrMetadata == nil {
            if CAEDRMetadata.isAvailable {
                metalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005,
                                                             maxLuminance: 1000.0,
                                                             opticalOutputScale: 100.0)
                print("Set default EDR metadata for HDR asset")
            } else {
                print("EDR tonemapping is not available; HDR content will likely clip")
            }
        }
    }
}
