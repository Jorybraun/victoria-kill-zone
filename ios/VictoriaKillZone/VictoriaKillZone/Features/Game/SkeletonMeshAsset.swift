#if canImport(SceneKit)
  import Foundation
  import SceneKit
  import simd

  /// Preprocessed indexed bone geometry; no OBJ parsing or mesh construction in
  /// a hit/pose update. Resource validation is bounded and fails closed.
  @MainActor
  enum SkeletonMeshAsset {
    struct Part {
      let name: String
      let bindTransform: simd_float4x4
      let geometry: SCNGeometry
    }
    enum AssetError: Error { case malformed }

    static var defaultURL: URL? {
      #if SWIFT_PACKAGE
        let bundle = Bundle.module
      #else
        let bundle = Bundle.main
      #endif
      return bundle.url(forResource: "HumanSkeleton", withExtension: "vkskeleton", subdirectory: "SkeletonAssets")
        ?? bundle.url(forResource: "HumanSkeleton", withExtension: "vkskeleton")
    }

    static let bundled: [Part] = {
      guard let url = defaultURL else { return [] }
      return (try? load(url)) ?? []
    }()

    static func load(_ url: URL) throws -> [Part] {
      let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard resource.isRegularFile == true, let size = resource.fileSize,
        (8...8_388_608).contains(size) else { throw AssetError.malformed }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      return try decode(data)
    }

    static func decode(_ data: Data) throws -> [Part] {
      guard (8...8_388_608).contains(data.count) else { throw AssetError.malformed }
      var reader = Reader(data: data)
      guard try reader.bytes(4) == Data("SKN1".utf8) else { throw AssetError.malformed }
      let count = try reader.uint32()
      guard count == SkeletonAnatomyPart.allCases.count else { throw AssetError.malformed }
      var result: [Part] = []
      var names = Set<String>()
      var triangles = 0
      for _ in 0..<count {
        let nameLength = try reader.uint16()
        guard nameLength > 0, nameLength <= 64,
          let name = String(data: try reader.bytes(nameLength), encoding: .utf8),
          SkeletonAnatomyPart(rawValue: name) != nil, names.insert(name).inserted
        else { throw AssetError.malformed }
        var matrix = matrix_identity_float4x4
        for column in 0..<4 {
          for row in 0..<4 {
            let value = try reader.float()
            guard value.isFinite else { throw AssetError.malformed }
            matrix[column][row] = value
          }
        }
        guard validBind(matrix) else { throw AssetError.malformed }
        let vertexCount = try reader.uint32()
        let indexCount = try reader.uint32()
        guard vertexCount > 0, vertexCount <= 100_000, indexCount > 0,
          indexCount % 3 == 0, indexCount <= 156_000 else { throw AssetError.malformed }
        triangles += indexCount / 3
        guard triangles <= 52_000 else { throw AssetError.malformed }
        let vertices = try reader.bytes(vertexCount * 40)
        let indices = try reader.bytes(indexCount * 4)
        try vertices.withUnsafeBytes { raw in
          func value(_ offset: Int) -> Float {
            Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
          }
          for start in stride(from: 0, to: raw.count, by: 40) {
            for offset in stride(from: start, to: start + 12, by: 4) {
              guard value(offset).isFinite, abs(value(offset)) <= 5 else { throw AssetError.malformed }
            }
            let normal = SIMD3<Float>(value(start + 12), value(start + 16), value(start + 20))
            let squaredLength = simd_length_squared(normal)
            guard squaredLength.isFinite, (0.98...1.02).contains(squaredLength) else { throw AssetError.malformed }
            for offset in stride(from: start + 24, to: start + 40, by: 4) {
              guard value(offset).isFinite, (0...1).contains(value(offset)) else { throw AssetError.malformed }
            }
          }
        }
        try indices.withUnsafeBytes { raw in
          for offset in stride(from: 0, to: raw.count, by: 4) {
            guard UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) < vertexCount
            else { throw AssetError.malformed }
          }
        }
        let position = SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: vertexCount,
          usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 40)
        let normal = SCNGeometrySource(data: vertices, semantic: .normal, vectorCount: vertexCount,
          usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: 40)
        let color = SCNGeometrySource(data: vertices, semantic: .color, vectorCount: vertexCount,
          usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 24, dataStride: 40)
        let element = SCNGeometryElement(data: indices, primitiveType: .triangles, primitiveCount: indexCount / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [position, normal, color], elements: [element])
        result.append(Part(name: name, bindTransform: matrix, geometry: geometry))
      }
      guard reader.offset == data.count else { throw AssetError.malformed }
      return result
    }

    /// Source frames must be affine, right-handed and orthogonal with positive
    /// anatomical reference lengths. Perspective, shear and singular transforms
    /// can produce invalid inverses or flip bone normals and are rejected.
    static func validBind(_ matrix: simd_float4x4) -> Bool {
      guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }),
        abs(matrix[0].w) < 0.000001, abs(matrix[1].w) < 0.000001,
        abs(matrix[2].w) < 0.000001, abs(matrix[3].w - 1) < 0.000001,
        abs(matrix[3].x) <= 5, abs(matrix[3].y) <= 5, abs(matrix[3].z) <= 5
      else { return false }
      let x = SIMD3<Float>(matrix[0].x, matrix[0].y, matrix[0].z)
      let y = SIMD3<Float>(matrix[1].x, matrix[1].y, matrix[1].z)
      let z = SIMD3<Float>(matrix[2].x, matrix[2].y, matrix[2].z)
      guard [x, y, z].allSatisfy({ (0.02...2).contains(simd_length($0)) }),
        simd_determinant(matrix) > 0.000001 else { return false }
      let nx = simd_normalize(x), ny = simd_normalize(y), nz = simd_normalize(z)
      return abs(simd_dot(nx, ny)) < 0.0001 && abs(simd_dot(nx, nz)) < 0.0001
        && abs(simd_dot(ny, nz)) < 0.0001
    }

    private struct Reader {
      let data: Data
      var offset = 0
      mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw AssetError.malformed }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
      }
      mutating func uint16() throws -> Int {
        Int(try bytes(2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) })
      }
      mutating func uint32() throws -> Int {
        Int(try bytes(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
      }
      mutating func float() throws -> Float { Float(bitPattern: UInt32(try uint32())) }
    }
  }
#endif
