import CryptoKit
import Foundation
import SceneKit

/// Plays surfaces evaluated after skinning in Blender on the skeletal clip's scene clock.
final class StrokeSurfaceAnimation {
  private struct Surface {
    let node: SCNNode
    let materials: [SCNMaterial]
    let vertexCount: Int
    let indexCount: Int
    let vertexOffset: Int
    let indexOffset: Int
  }

  private enum CacheError: Error { case invalid }

  private static let headerSize = 96
  private static let bytesPerVertex = 6 * MemoryLayout<Float>.size
  private let bytes: Data
  private let sampleCount: Int
  private let sampleRate: Double
  private let vertexStride: Int
  private let indexStride: Int
  private let indicesStart: Int
  private let surfaces: [Surface]
  private var lastSample = -1.0

  init(url: URL, assetURL: URL, model: SCNNode, duration: Double) throws {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    guard bytes.count >= Self.headerSize,
          bytes.prefix(8).elementsEqual("BRMSH001".utf8) else { throw CacheError.invalid }
    let fields = bytes.withUnsafeBytes { buffer in
      (0..<6).map { Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 8 + $0 * 4, as: UInt32.self))) }
    }
    let sampleCount = fields[0], sampleRate = Double(fields[1])
    let vertexCounts = [fields[2], fields[3]], indexCounts = [fields[4], fields[5]]
    guard (2...1_000).contains(sampleCount), sampleRate == 120,
          abs(Double(sampleCount - 1) / sampleRate - duration) < 0.000001,
          vertexCounts.allSatisfy({ (1...Int(UInt16.max)).contains($0) }),
          indexCounts.allSatisfy({ (3...100_000).contains($0) && $0.isMultiple(of: 3) })
    else { throw CacheError.invalid }

    let vertexStride = vertexCounts.reduce(0, +) * Self.bytesPerVertex
    let indexStride = indexCounts.reduce(0, +) * MemoryLayout<UInt16>.size
    let indicesStart = Self.headerSize + sampleCount * vertexStride
    guard bytes.count == indicesStart + sampleCount * indexStride else { throw CacheError.invalid }
    let digest = SHA256.hash(data: try Data(contentsOf: assetURL, options: .mappedIfSafe))
    guard bytes[32..<64].elementsEqual(digest),
          bytes[64..<Self.headerSize].elementsEqual(SHA256.hash(data: bytes[Self.headerSize...]))
    else { throw CacheError.invalid }

    var surfaces: [Surface] = []
    var vertexOffset = 0, indexOffset = 0
    for (surfaceIndex, name) in ["P030ArmR", "P030ArmL"].enumerated() {
      guard let node = model.childNode(withName: name, recursively: true),
            let materials = node.geometry?.materials, !materials.isEmpty else { throw CacheError.invalid }
      let vertexCount = vertexCounts[surfaceIndex], indexCount = indexCounts[surfaceIndex]
      let validIndices = bytes.withUnsafeBytes { buffer in
        for sample in 0..<sampleCount {
          let start = indicesStart + sample * indexStride + indexOffset
          for index in 0..<indexCount {
            let value = buffer.loadUnaligned(fromByteOffset: start + index * 2, as: UInt16.self)
            if Int(value) >= vertexCount { return false }
          }
        }
        return true
      }
      guard validIndices else { throw CacheError.invalid }
      surfaces.append(Surface(node: node, materials: materials, vertexCount: vertexCount, indexCount: indexCount,
                              vertexOffset: vertexOffset, indexOffset: indexOffset))
      vertexOffset += vertexCount * Self.bytesPerVertex
      indexOffset += indexCount * MemoryLayout<UInt16>.size
    }

    self.bytes = bytes
    self.sampleCount = sampleCount
    self.sampleRate = sampleRate
    self.vertexStride = vertexStride
    self.indexStride = indexStride
    self.indicesStart = indicesStart
    self.surfaces = surfaces
    show(at: 0)
  }

  func show(at time: Double) {
    let position = max(0, min(Double(sampleCount - 1), time * sampleRate))
    let rounded = position.rounded()
    let sample = abs(position - rounded) < 1e-9 ? rounded : position
    guard sample != lastSample else { return }
    lastSample = sample
    let nearest = Int(sample.rounded())
    let lower = Int(sample)
    let upper = min(lower + 1, sampleCount - 1)
    let fraction = Float(sample - Double(lower))

    for surface in surfaces {
      let length = surface.vertexCount * Self.bytesPerVertex
      let start = Self.headerSize + lower * vertexStride + surface.vertexOffset
      let source: Data
      if fraction == 0 {
        source = bytes.subdata(in: start..<(start + length))
      } else {
        let next = Self.headerSize + upper * vertexStride + surface.vertexOffset
        source = interpolatedVertices(start: start, next: next, count: length, fraction: fraction)
      }
      let position = vertexSource(source, semantic: .vertex, count: surface.vertexCount, offset: 0)
      let normal = vertexSource(source, semantic: .normal, count: surface.vertexCount, offset: 3 * MemoryLayout<Float>.size)
      let indexStart = indicesStart + nearest * indexStride + surface.indexOffset
      let indexEnd = indexStart + surface.indexCount * MemoryLayout<UInt16>.size
      let element = SCNGeometryElement(data: bytes.subdata(in: indexStart..<indexEnd),
                                       primitiveType: .triangles, primitiveCount: surface.indexCount / 3,
                                       bytesPerIndex: MemoryLayout<UInt16>.size)
      let geometry = SCNGeometry(sources: [position, normal], elements: [element])
      geometry.materials = surface.materials
      surface.node.geometry = geometry
    }
  }

  private func vertexSource(_ data: Data, semantic: SCNGeometrySource.Semantic,
                            count: Int, offset: Int) -> SCNGeometrySource {
    SCNGeometrySource(data: data, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                      componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
                      dataOffset: offset, dataStride: Self.bytesPerVertex)
  }

  private func interpolatedVertices(start: Int, next: Int, count: Int, fraction: Float) -> Data {
    var vertices = Data(count: count)
    bytes.withUnsafeBytes { input in
      vertices.withUnsafeMutableBytes { output in
        let floats = output.bindMemory(to: Float.self)
        for index in floats.indices {
          let offset = index * MemoryLayout<Float>.size
          let a = input.loadUnaligned(fromByteOffset: start + offset, as: Float.self)
          let b = input.loadUnaligned(fromByteOffset: next + offset, as: Float.self)
          floats[index] = a + fraction * (b - a)
        }
      }
    }
    return vertices
  }
}
