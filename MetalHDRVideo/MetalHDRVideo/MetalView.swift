import MetalKit
import SwiftUI

protocol RenderDelegate : AnyObject, MTKViewDelegate {
    func configure(view: MTKView)
}

#if os(macOS)

struct MetalView : NSViewRepresentable {
    typealias NSViewType = MTKView
    typealias CoordinatorType = RenderDelegate

    let delegate: RenderDelegate

    func makeNSView(context: Context) -> MTKView {
        return MTKView()
    }
    
    func updateNSView(_ view: MTKView, context: Context) {
        delegate.configure(view: view)
        view.delegate = delegate
    }

    func makeCoordinator() -> RenderDelegate {
        return delegate
    }
}

#else

struct MetalView : UIViewRepresentable {
    typealias UIViewType = MTKView
    typealias CoordinatorType = RenderDelegate

    let delegate: RenderDelegate

    func makeUIView(context: Context) -> MTKView {
        return MTKView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        delegate.configure(view: view)
        view.delegate = delegate
    }

    func makeCoordinator() -> RenderDelegate {
        return delegate
    }
}

#endif
