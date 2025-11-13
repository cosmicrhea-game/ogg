import COgg
import Foundation

// MARK: - OggStream

/// Swift-idiomatic wrapper for Ogg bitstream encoding and decoding
///
/// This class wraps `ogg_stream_state` and provides a clean interface for:
/// - Encoding: Adding packets and generating pages
/// - Decoding: Receiving pages and extracting packets
public final class OggStream {
  private var streamState: ogg_stream_state
  private var isInitialized = false

  /// The serial number for this stream
  public let serialNumber: Int32

  /// Initialize a new Ogg stream with a serial number
  /// - Parameter serialNumber: Unique serial number for this stream. If nil, a random number is generated.
  public init(serialNumber: Int32? = nil) throws {
    let serial = serialNumber ?? Int32.random(in: 1...Int32.max)
    self.serialNumber = serial

    var state = ogg_stream_state()
    let result = ogg_stream_init(&state, serial)

    guard result == 0 else {
      throw OggError.streamInitializationFailed(
        "Failed to initialize stream with serial number \(serial)")
    }

    self.streamState = state
    self.isInitialized = true
  }

  /// Add a packet to the stream for encoding
  /// - Parameters:
  ///   - packet: The packet to add
  /// - Returns: `true` if the packet was successfully added
  public func addPacket(_ packet: OggPacket) throws -> Bool {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    return try packet.data.withUnsafeBytes { dataBytes in
      let dataPtr = dataBytes.bindMemory(to: UInt8.self)
      var cPacket = ogg_packet()
      cPacket.packet = UnsafeMutablePointer<UInt8>(mutating: dataPtr.baseAddress!)
      cPacket.bytes = packet.data.count
      cPacket.b_o_s = packet.isBeginningOfStream ? 1 : 0
      cPacket.e_o_s = packet.isEndOfStream ? 1 : 0
      cPacket.granulepos = packet.granulePosition
      cPacket.packetno = packet.packetNumber

      let result = ogg_stream_packetin(&streamState, &cPacket)

      guard result == 0 else {
        throw OggError.packetAddFailed("Failed to add packet to stream")
      }

      return true
    }
  }

  /// Generate a page from the stream (for encoding)
  /// - Parameter fillBytes: Minimum number of bytes to fill the page with. If nil, uses default behavior.
  /// - Returns: A page if one is available, `nil` otherwise
  public func generatePage(fillBytes: Int? = nil) throws -> OggPage? {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    var cPage = ogg_page()
    let result: Int32

    if let fill = fillBytes {
      result = ogg_stream_pageout_fill(&streamState, &cPage, Int32(fill))
    } else {
      result = ogg_stream_pageout(&streamState, &cPage)
    }

    guard result != 0 else {
      return nil  // No page available yet
    }

    return OggPage(from: cPage)
  }

  /// Flush remaining data into a page (for encoding)
  /// - Parameter fillBytes: Minimum number of bytes to fill the page with. If nil, uses default behavior.
  /// - Returns: A page if one is available, `nil` otherwise
  public func flushPage(fillBytes: Int? = nil) throws -> OggPage? {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    var cPage = ogg_page()
    let result: Int32

    if let fill = fillBytes {
      result = ogg_stream_flush_fill(&streamState, &cPage, Int32(fill))
    } else {
      result = ogg_stream_flush(&streamState, &cPage)
    }

    guard result != 0 else {
      return nil  // No page available
    }

    return OggPage(from: cPage)
  }

  /// Add a page to the stream (for decoding)
  /// - Parameter page: The page to add
  /// - Returns: `true` if the page was successfully added
  public func addPage(_ page: OggPage) throws -> Bool {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    return try page.header.withUnsafeBytes { headerBytes in
      let headerPtr = headerBytes.bindMemory(to: UInt8.self)
      return try page.body.withUnsafeBytes { bodyBytes in
        let bodyPtr = bodyBytes.bindMemory(to: UInt8.self)
        var cPage = ogg_page()
        cPage.header = UnsafeMutablePointer<UInt8>(mutating: headerPtr.baseAddress!)
        cPage.header_len = page.header.count
        cPage.body = UnsafeMutablePointer<UInt8>(mutating: bodyPtr.baseAddress!)
        cPage.body_len = page.body.count

        let result = ogg_stream_pagein(&streamState, &cPage)

        guard result == 0 else {
          throw OggError.pageAddFailed("Failed to add page to stream")
        }

        return true
      }
    }
  }

  /// Extract a packet from the stream (for decoding)
  /// - Returns: A packet if one is available, `nil` otherwise
  public func extractPacket() throws -> OggPacket? {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    var cPacket = ogg_packet()
    let result = ogg_stream_packetout(&streamState, &cPacket)

    guard result != 0 else {
      return nil  // No packet available yet
    }

    return OggPacket(from: cPacket)
  }

  /// Peek at the next packet without removing it (for decoding)
  /// - Returns: A packet if one is available, `nil` otherwise
  public func peekPacket() throws -> OggPacket? {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    var cPacket = ogg_packet()
    let result = ogg_stream_packetpeek(&streamState, &cPacket)

    guard result != 0 else {
      return nil  // No packet available
    }

    return OggPacket(from: cPacket)
  }

  /// Check if the stream has reached end-of-stream
  public var isEndOfStream: Bool {
    guard isInitialized else { return false }
    return ogg_stream_eos(&streamState) != 0
  }

  /// Reset the stream state
  public func reset() throws {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    let result = ogg_stream_reset(&streamState)
    guard result == 0 else {
      throw OggError.streamResetFailed("Failed to reset stream")
    }
  }

  /// Reset the stream with a new serial number
  /// - Parameter serialNumber: New serial number for the stream
  public func reset(serialNumber: Int32) throws {
    guard isInitialized else {
      throw OggError.streamNotInitialized
    }

    let result = ogg_stream_reset_serialno(&streamState, serialNumber)
    guard result == 0 else {
      throw OggError.streamResetFailed("Failed to reset stream with new serial number")
    }
  }

  deinit {
    if isInitialized {
      ogg_stream_clear(&streamState)
    }
  }
}

// MARK: - OggSync

/// Swift-idiomatic wrapper for Ogg page synchronization (decoding)
///
/// This class wraps `ogg_sync_state` and is used to synchronize with pages
/// in a raw byte stream during decoding.
public final class OggSync {
  private var syncState: ogg_sync_state
  private var isInitialized = false

  /// Initialize a new Ogg sync state
  public init() throws {
    var state = ogg_sync_state()
    let result = ogg_sync_init(&state)

    guard result == 0 else {
      throw OggError.syncInitializationFailed("Failed to initialize sync state")
    }

    self.syncState = state
    self.isInitialized = true
  }

  /// Get a buffer to write raw data into
  /// - Parameter size: Size of the buffer needed
  /// - Returns: A buffer pointer to write data into, or `nil` on failure
  public func getBuffer(size: Int) throws -> UnsafeMutablePointer<CChar>? {
    guard isInitialized else {
      throw OggError.syncNotInitialized
    }

    return ogg_sync_buffer(&syncState, size)
  }

  /// Notify the sync state how many bytes were written to the buffer
  /// - Parameter bytesWritten: Number of bytes written
  public func wrote(bytesWritten: Int) throws {
    guard isInitialized else {
      throw OggError.syncNotInitialized
    }

    let result = ogg_sync_wrote(&syncState, bytesWritten)
    guard result == 0 else {
      throw OggError.syncWriteFailed("Failed to notify sync state of written bytes")
    }
  }

  /// Try to find and extract a page from the buffered data
  /// - Returns: A page if one is found, `nil` otherwise
  public func extractPage() throws -> OggPage? {
    guard isInitialized else {
      throw OggError.syncNotInitialized
    }

    var cPage = ogg_page()
    let result = ogg_sync_pageout(&syncState, &cPage)

    guard result != 0 else {
      return nil  // No page found yet
    }

    return OggPage(from: cPage)
  }

  /// Seek to the next page boundary in the buffered data
  /// - Returns: Number of bytes to skip, or 0 if no page found
  public func seekPage() throws -> Int {
    guard isInitialized else {
      throw OggError.syncNotInitialized
    }

    var cPage = ogg_page()
    let result = ogg_sync_pageseek(&syncState, &cPage)

    return Int(result)
  }

  /// Reset the sync state
  public func reset() throws {
    guard isInitialized else {
      throw OggError.syncNotInitialized
    }

    let result = ogg_sync_reset(&syncState)
    guard result == 0 else {
      throw OggError.syncResetFailed("Failed to reset sync state")
    }
  }

  deinit {
    if isInitialized {
      ogg_sync_clear(&syncState)
    }
  }
}

// MARK: - OggPage

/// Represents an Ogg page
public struct OggPage {
  /// Page header data
  public let header: Data
  /// Page body data
  public let body: Data

  /// Version number (should be 0)
  public let version: Int32
  /// Whether this page continues from the previous page
  public let isContinued: Bool
  /// Whether this is the beginning of stream
  public let isBeginningOfStream: Bool
  /// Whether this is the end of stream
  public let isEndOfStream: Bool
  /// Granule position
  public let granulePosition: Int64
  /// Serial number
  public let serialNumber: Int32
  /// Page number
  public let pageNumber: Int64
  /// Number of packets in this page
  public let packetCount: Int32

  init(from cPage: ogg_page) {
    // Copy header
    let headerLen = Int(cPage.header_len)
    self.header = Data(bytes: cPage.header, count: headerLen)

    // Copy body
    let bodyLen = Int(cPage.body_len)
    self.body = Data(bytes: cPage.body, count: bodyLen)

    // Extract metadata (need mutable copy for inout parameters)
    var mutablePage = cPage
    self.version = ogg_page_version(&mutablePage)
    self.isContinued = ogg_page_continued(&mutablePage) != 0
    self.isBeginningOfStream = ogg_page_bos(&mutablePage) != 0
    self.isEndOfStream = ogg_page_eos(&mutablePage) != 0
    self.granulePosition = ogg_page_granulepos(&mutablePage)
    self.serialNumber = ogg_page_serialno(&mutablePage)
    self.pageNumber = Int64(ogg_page_pageno(&mutablePage))
    self.packetCount = ogg_page_packets(&mutablePage)
  }

}

// MARK: - OggPacket

/// Represents an Ogg packet
public struct OggPacket {
  /// Packet data
  public let data: Data
  /// Whether this is the beginning of stream
  public let isBeginningOfStream: Bool
  /// Whether this is the end of stream
  public let isEndOfStream: Bool
  /// Granule position
  public let granulePosition: Int64
  /// Packet sequence number
  public let packetNumber: Int64

  /// Create a new packet
  /// - Parameters:
  ///   - data: Packet data
  ///   - isBeginningOfStream: Whether this is the beginning of stream
  ///   - isEndOfStream: Whether this is the end of stream
  ///   - granulePosition: Granule position
  ///   - packetNumber: Packet sequence number
  public init(
    data: Data,
    isBeginningOfStream: Bool = false,
    isEndOfStream: Bool = false,
    granulePosition: Int64 = -1,
    packetNumber: Int64 = -1
  ) {
    self.data = data
    self.isBeginningOfStream = isBeginningOfStream
    self.isEndOfStream = isEndOfStream
    self.granulePosition = granulePosition
    self.packetNumber = packetNumber
  }

  init(from cPacket: ogg_packet) {
    let bytes = Int(cPacket.bytes)
    self.data = Data(bytes: cPacket.packet, count: bytes)
    self.isBeginningOfStream = cPacket.b_o_s != 0
    self.isEndOfStream = cPacket.e_o_s != 0
    self.granulePosition = cPacket.granulepos
    self.packetNumber = cPacket.packetno
  }

}

// MARK: - OggError

/// Errors that can occur during Ogg operations
public enum OggError: Error, LocalizedError, Equatable {
  case streamNotInitialized
  case streamInitializationFailed(String)
  case streamResetFailed(String)
  case packetAddFailed(String)
  case pageAddFailed(String)
  case syncNotInitialized
  case syncInitializationFailed(String)
  case syncResetFailed(String)
  case syncWriteFailed(String)

  public var errorDescription: String? {
    switch self {
    case .streamNotInitialized:
      return "Stream not initialized"
    case .streamInitializationFailed(let message):
      return "Stream initialization failed: \(message)"
    case .streamResetFailed(let message):
      return "Stream reset failed: \(message)"
    case .packetAddFailed(let message):
      return "Failed to add packet: \(message)"
    case .pageAddFailed(let message):
      return "Failed to add page: \(message)"
    case .syncNotInitialized:
      return "Sync state not initialized"
    case .syncInitializationFailed(let message):
      return "Sync initialization failed: \(message)"
    case .syncResetFailed(let message):
      return "Sync reset failed: \(message)"
    case .syncWriteFailed(let message):
      return "Sync write failed: \(message)"
    }
  }
}
