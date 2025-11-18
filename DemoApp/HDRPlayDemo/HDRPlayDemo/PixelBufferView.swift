//
//  PixelBufferView.swift
//  HDRPlayDemo
//
//  Created by Andrew Sartor on 2025/11/18.
//

import CoreImage
import SwiftUI

struct PixelBufferView: View {
    let pixelBuffer: CVPixelBuffer
    
    var body: some View {
        GeometryReader { geometry in
            if let cgImage = convertPixelBufferToCGImage(pixelBuffer) {
                Image(cgImage, scale: 1.0, label: Text("Video Frame"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
    
    private func convertPixelBufferToCGImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
