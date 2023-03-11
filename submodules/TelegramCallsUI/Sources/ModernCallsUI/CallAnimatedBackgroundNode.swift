import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import HierarchyTrackingLayer
import MetalKit
import MetalImageView

private func shiftArray(array: [CGPoint], offset: Int) -> [CGPoint] {
    var newArray = array
    var offset = offset
    while offset > 0 {
        let element = newArray.removeFirst()
        newArray.append(element)
        offset -= 1
    }
    return newArray
}

private func gatherPositions(_ list: [CGPoint]) -> [CGPoint] {
    var result: [CGPoint] = []
    for i in 0 ..< list.count / 2 {
        result.append(list[i * 2])
    }
    return result
}

private func interpolateFloat(_ value1: CGFloat, _ value2: CGFloat, at factor: CGFloat) -> CGFloat {
    return value1 * (1.0 - factor) + value2 * factor
}

private func interpolatePoints(_ point1: CGPoint, _ point2: CGPoint, at factor: CGFloat) -> CGPoint {
    return CGPoint(x: interpolateFloat(point1.x, point2.x, at: factor), y: interpolateFloat(point1.y, point2.y, at: factor))
}

enum CallAnimatedBackgroundState {
    case waiting
    case active
    case weak
}

final class CallAnimatedBackgroundNode: ASDisplayNode {
    
    struct FragmentIn {
        var frameIndex: Int
        var positions: matrix_float4x2
        var colors: matrix_float4x3
    }
    
    private var metalView: MTKView {
        return view as! MTKView
    }
    
    private var renderer: Renderer?
    
    private var state: CallAnimatedBackgroundState = .waiting
    
    private let maxFrame: Int = 8 * 60
    
    private var fragmentInput: FragmentIn
    
    private let colors: [CallAnimatedBackgroundState : matrix_float4x3] = [
        .waiting : .init(
            SIMD3<Float>(hex: 0x5295D6),
            SIMD3<Float>(hex: 0x616AD5),
            SIMD3<Float>(hex: 0xAC65D4),
            SIMD3<Float>(hex: 0x7261DA)
        ),
        .active : .init(
            SIMD3<Float>(hex: 0xBAC05D),
            SIMD3<Float>(hex: 0x3C9C8F),
            SIMD3<Float>(hex: 0x398D6F),
            SIMD3<Float>(hex: 0x53A6DE)
        ),
        .weak : .init(
            SIMD3<Float>(hex: 0xB84498),
            SIMD3<Float>(hex: 0xF4992E),
            SIMD3<Float>(hex: 0xC94986),
            SIMD3<Float>(hex: 0xFF7E46)
        )
    ]
    
    private static let basePositions: [CGPoint] = [
        CGPoint(x: 0.80, y: 0.10),
        CGPoint(x: 0.60, y: 0.20),
        CGPoint(x: 0.35, y: 0.25),
        CGPoint(x: 0.25, y: 0.60),
        CGPoint(x: 0.20, y: 0.90),
        CGPoint(x: 0.40, y: 0.80),
        CGPoint(x: 0.65, y: 0.75),
        CGPoint(x: 0.75, y: 0.40)
    ]

    private var morphedPositions: [Int : matrix_float4x2] = [:]
    
    override init() {
        self.renderer = Renderer()
        
        var steps: [[CGPoint]] = []
        for phase in 0 ... 8 {
            steps.append(gatherPositions(shiftArray(array: CallAnimatedBackgroundNode.basePositions, offset: phase)))
        }
        
        let stepCount = steps.count - 1

        let fps: Double = 60
        let maxFrame = Int(8 * fps)
        let framesPerAnyStep = maxFrame / stepCount
        
        var morphedPositions: [Int : matrix_float4x2] = [:]
        for frameIndex in 0 ..< maxFrame {
            let t = CGFloat(frameIndex) / CGFloat(maxFrame - 1)
            let globalStep = Int(t * CGFloat(maxFrame))
            let stepIndex = min(stepCount - 1, globalStep / framesPerAnyStep)
            
            let stepFrameIndex = globalStep - stepIndex * framesPerAnyStep
            let stepFrames: Int
            if stepIndex == stepCount - 1 {
                stepFrames = maxFrame - framesPerAnyStep * (stepCount - 1)
            } else {
                stepFrames = framesPerAnyStep
            }
            let stepT = CGFloat(stepFrameIndex) / CGFloat(stepFrames - 1)
            
            var positions: [CGPoint] = []
            for i in 0 ..< steps[0].count {
                positions.append(interpolatePoints(steps[stepIndex][i], steps[stepIndex + 1][i], at: stepT))
            }
            morphedPositions[frameIndex] = matrix_float4x2(positions[0].simd, positions[1].simd, positions[2].simd, positions[3].simd)
        }
        self.morphedPositions = morphedPositions
        
        self.fragmentInput = FragmentIn(frameIndex: 0, positions: morphedPositions[0]!, colors: colors[.waiting]!)

        super.init()
        
        self.setViewBlock {
            return MTKView(frame: .zero)
        }
        
        metalView.delegate = self
        
        renderer?.set(view: metalView)
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        if self.metalView.drawableSize != size {
            self.metalView.drawableSize = size
            transition.updateFrame(view: self.metalView, frame: CGRect(origin: CGPoint(), size: size))
        }
    }
    
    func startAnimating() {
        metalView.isPaused = false
        metalView.draw()
    }
    
    private var intermediateColors: [matrix_float4x3]?
    private var colorIndex: Int = 0
    private let framesPerChange = 30
    
    func set(state: CallAnimatedBackgroundState, animated: Bool = true) {
        guard self.state != state else { return }
        let previousColors = intermediateColors?[colorIndex] ?? colors[self.state]!
        let currentColors = colors[state]!
        
        let dif0 = (currentColors.columns.0 - previousColors.columns.0) / Float(framesPerChange)
        let dif1 = (currentColors.columns.1 - previousColors.columns.1) / Float(framesPerChange)
        let dif2 = (currentColors.columns.2 - previousColors.columns.2) / Float(framesPerChange)
        let dif3 = (currentColors.columns.3 - previousColors.columns.3) / Float(framesPerChange)
        
        var intermediateColors: [matrix_float4x3] = []
        for frame in 0 ..< framesPerChange {
            let col1 = previousColors.columns.0 + (dif0 * Float(frame))
            let col2 = previousColors.columns.1 + (dif1 * Float(frame))
            let col3 = previousColors.columns.2 + (dif2 * Float(frame))
            let col4 = previousColors.columns.3 + (dif3 * Float(frame))

            intermediateColors.append(matrix_float4x3(col1, col2, col3, col4))
        }
        self.intermediateColors = intermediateColors
        self.colorIndex = 0

        self.state = state
        
        if animated {
            if metalView.isPaused {
                startAnimating()
            }
        } else {
            startAnimating()
            stopAnimating()
        }
    }
    
    func stopAnimating() {
        metalView.isPaused = true
    }
}

extension CallAnimatedBackgroundNode: MTKViewDelegate {
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    
    func draw(in view: MTKView) {
        fragmentInput.frameIndex = (fragmentInput.frameIndex + 1) % maxFrame
        fragmentInput.positions = morphedPositions[fragmentInput.frameIndex]!
        
        if let intermediateColors, colorIndex < framesPerChange {
            fragmentInput.colors = intermediateColors[self.colorIndex]
            self.colorIndex += 1
        } else {
            intermediateColors = nil
            fragmentInput.colors = colors[state]!
        }
        
        renderer?.draw(in: view, fragmentInput: &fragmentInput)
    }
}

extension CallAnimatedBackgroundNode {
    
    class Renderer {
        fileprivate let device: MTLDevice
        fileprivate let renderPipelineState: MTLRenderPipelineState

        private let commandQueue: MTLCommandQueue
        
        private weak var metalView: MTKView?
        
        private var frameIndex: Int = 0
        private var previousColors = [SIMD4<Float>(0, 0, 0, 0)]

        init?() {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return nil
            }
            self.device = device

            let mainBundle = Bundle(for: CallAnimatedBackgroundNode.self)

            guard let path = mainBundle.path(forResource: "TelegramCallsUIBundle", ofType: "bundle") else {
                return nil
            }
            guard let bundle = Bundle(path: path) else {
                return nil
            }
            guard let defaultLibrary = try? self.device.makeDefaultLibrary(bundle: bundle) else {
                return nil
            }

            func makePipelineState(vertexProgram: String, fragmentProgram: String) -> MTLRenderPipelineState? {
                guard let loadedVertexProgram = defaultLibrary.makeFunction(name: vertexProgram) else {
                    return nil
                }
                guard let loadedFragmentProgram = defaultLibrary.makeFunction(name: fragmentProgram) else {
                    return nil
                }

                let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
                pipelineStateDescriptor.vertexFunction = loadedVertexProgram
                pipelineStateDescriptor.fragmentFunction = loadedFragmentProgram
                pipelineStateDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineStateDescriptor) else {
                    return nil
                }

                return pipelineState
            }

            guard let renderPipelineState = makePipelineState(vertexProgram: "gradientVertex", fragmentProgram: "gradientFragment") else {
                return nil
            }
            self.renderPipelineState = renderPipelineState

            guard let commandQueue = self.device.makeCommandQueue() else {
                return nil
            }
            self.commandQueue = commandQueue
        }
        
        func set(view: MTKView) {
            self.metalView = view
            self.metalView?.device = device
            self.metalView?.preferredFramesPerSecond = 60
        }

        func draw(in view: MTKView, fragmentInput: inout FragmentIn) {
            guard let drawable = view.currentDrawable else { return }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            
            let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
            commandEncoder?.setRenderPipelineState(renderPipelineState)
            commandEncoder?.setFragmentBytes(&fragmentInput, length: MemoryLayout<FragmentIn>.size, index: 0)
            commandEncoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            commandEncoder?.endEncoding()
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

fileprivate extension SIMD3<Float> {
    init(hex: UInt32) {
        self.init(
            Float((hex >> 16) & 0xff) / 255.0,
            Float((hex >> 8) & 0xff) / 255.0,
            Float(hex & 0xff) / 255.0
        )
    }
}

fileprivate extension CGPoint {
    var simd: simd_float2 {
        return simd_float2(Float(x), Float(y))
    }
}
