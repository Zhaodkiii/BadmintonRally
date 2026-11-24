import CoreMedia
import Foundation

struct CourtVideoFrame: Codable {
  let match: UUID
  let time: Double
  let bytes: Data
  let parameters: [Data]

  // Marker, UUID, capture time, SPS/PPS lengths, then raw AVCC bytes.
  func wireData() -> Data {
    var id = match.uuid
    var stamp = time.bitPattern.bigEndian
    var data = Data([0])
    withUnsafeBytes(of: &id) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &stamp) { data.append(contentsOf: $0) }
    for index in 0..<2 {
      let set = parameters.count == 2 ? parameters[index] : Data()
      var size = UInt16(set.count).bigEndian
      withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
      data.append(set)
    }
    data.append(bytes)
    return data
  }

  init?(wire data: Data) {
    guard data.count >= 30, data.first == 0 else { return nil }
    match = UUID(uuid: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: uuid_t.self) })
    time = Double(bitPattern: data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 17, as: UInt64.self)) })
    var cursor = 25
    var sets: [Data] = []
    for _ in 0..<2 {
      guard cursor + 2 <= data.count else { return nil }
      let size = Int(data[cursor]) * 256 + Int(data[cursor + 1])
      cursor += 2
      guard size <= 1024, cursor + size <= data.count else { return nil }
      if size > 0 { sets.append(data.subdata(in: cursor..<(cursor + size))) }
      cursor += size
    }
    guard sets.isEmpty || sets.count == 2, (1..<180_000).contains(data.count - cursor) else { return nil }
    parameters = sets
    bytes = data.subdata(in: cursor..<data.count)
  }

  init?(match: UUID, time: Double, sample: CMSampleBuffer) {
    guard let block = sample.dataBuffer, let format = sample.formatDescription,
          (1..<180_000).contains(block.dataLength) else { return nil }
    var payload = Data(count: block.dataLength)
    guard payload.withUnsafeMutableBytes({
      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: block.dataLength, destination: $0.baseAddress!)
    }) == noErr else { return nil }
    let flags = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])?.first
    var sets: [Data] = []
    if flags?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true {
      for index in 0..<2 {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var header: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
          parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
          nalUnitHeaderLengthOut: &header) == noErr, let pointer, header == 4 else { return nil }
        sets.append(Data(bytes: pointer, count: size))
      }
    }
    self.match = match
    self.time = time
    bytes = payload
    parameters = sets
  }

  func format() -> CMVideoFormatDescription? {
    guard parameters.count == 2, parameters.allSatisfy({ (1...1024).contains($0.count) }) else { return nil }
    var format: CMVideoFormatDescription?
    parameters[0].withUnsafeBytes { first in
      parameters[1].withUnsafeBytes { second in
        let pointers = [first.bindMemory(to: UInt8.self).baseAddress!, second.bindMemory(to: UInt8.self).baseAddress!]
        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
          parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: parameters.map(\.count),
          nalUnitHeaderLength: 4, formatDescriptionOut: &format)
      }
    }
    return format
  }

  func sample(format: CMVideoFormatDescription, elapsed: Double) -> CMSampleBuffer? {
    guard (1..<180_000).contains(bytes.count) else { return nil }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
      blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
      offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &block) == noErr, let block else { return nil }
    guard bytes.withUnsafeBytes({
      CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
    }) == noErr else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: CMTime(seconds: elapsed, preferredTimescale: 60000), decodeTimeStamp: .invalid)
    var size = bytes.count
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
      formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
    if parameters.isEmpty, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                          Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}
