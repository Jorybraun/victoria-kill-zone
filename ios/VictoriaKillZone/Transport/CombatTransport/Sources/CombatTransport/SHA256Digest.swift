import Foundation

enum SHA256Digest {
  static func hash(_ data: Data) -> Data {
    #if canImport(CryptoKit)
    return Data(SHA256.hash(data: data))
    #else
    return portableHash(data)
    #endif
  }

  private static let constants: [UInt32] = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
    0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
    0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
    0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
    0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
    0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
  ]

  static func portableHash(_ data: Data) -> Data {
    var message = Array(data)
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 {
      message.append(0)
    }
    message.append(contentsOf: [
      UInt8((bitLength >> 56) & 0xFF),
      UInt8((bitLength >> 48) & 0xFF),
      UInt8((bitLength >> 40) & 0xFF),
      UInt8((bitLength >> 32) & 0xFF),
      UInt8((bitLength >> 24) & 0xFF),
      UInt8((bitLength >> 16) & 0xFF),
      UInt8((bitLength >> 8) & 0xFF),
      UInt8(bitLength & 0xFF),
    ])

    var hash: [UInt32] = [
      0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
      0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    for offset in stride(from: 0, to: message.count, by: 64) {
      var words = Array(repeating: UInt32(0), count: 64)
      for index in 0..<16 {
        let start = offset + index * 4
        words[index] =
          UInt32(message[start]) << 24
          | UInt32(message[start + 1]) << 16
          | UInt32(message[start + 2]) << 8
          | UInt32(message[start + 3])
      }
      for index in 16..<64 {
        let s0 = words[index - 15].rotateRight(7)
          ^ words[index - 15].rotateRight(18)
          ^ (words[index - 15] >> 3)
        let s1 = words[index - 2].rotateRight(17)
          ^ words[index - 2].rotateRight(19)
          ^ (words[index - 2] >> 10)
        words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
      }

      var values = hash
      for index in 0..<64 {
        let s1 = values[4].rotateRight(6)
          ^ values[4].rotateRight(11)
          ^ values[4].rotateRight(25)
        let choice = (values[4] & values[5]) ^ (~values[4] & values[6])
        let temp1 = values[7] &+ s1 &+ choice &+ constants[index] &+ words[index]
        let s0 = values[0].rotateRight(2)
          ^ values[0].rotateRight(13)
          ^ values[0].rotateRight(22)
        let majority = (values[0] & values[1])
          ^ (values[0] & values[2])
          ^ (values[1] & values[2])
        let temp2 = s0 &+ majority
        values = [
          temp1 &+ temp2,
          values[0],
          values[1],
          values[2],
          values[3] &+ temp1,
          values[4],
          values[5],
          values[6],
        ]
      }
      for index in 0..<8 {
        hash[index] = hash[index] &+ values[index]
      }
    }

    var result = Data()
    for value in hash {
      result.append(UInt8((value >> 24) & 0xFF))
      result.append(UInt8((value >> 16) & 0xFF))
      result.append(UInt8((value >> 8) & 0xFF))
      result.append(UInt8(value & 0xFF))
    }
    return result
  }
}

private extension UInt32 {
  func rotateRight(_ amount: UInt32) -> UInt32 {
    (self >> amount) | (self << (32 - amount))
  }
}
